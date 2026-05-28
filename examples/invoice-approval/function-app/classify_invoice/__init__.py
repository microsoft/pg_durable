# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

import json
import re
from typing import Any

import azure.functions as func


def _json_error(status_code: int, code: str, message: str) -> func.HttpResponse:
    body = {"error": code, "message": message}
    return func.HttpResponse(
        json.dumps(body),
        status_code=status_code,
        mimetype="application/json",
    )


# Simple keyword-based categorization (deterministic, no AI dependency)
CATEGORY_KEYWORDS: dict[str, list[str]] = {
    "software": ["license", "software", "saas", "subscription", "cloud", "azure", "aws"],
    "consulting": ["consulting", "advisory", "professional services", "engagement"],
    "hardware": ["server", "laptop", "hardware", "equipment", "device", "monitor"],
    "facilities": ["rent", "lease", "utilities", "maintenance", "cleaning", "office"],
    "travel": ["travel", "flight", "hotel", "airfare", "per diem", "mileage"],
    "marketing": ["marketing", "advertising", "campaign", "sponsorship", "event"],
    "supplies": ["supplies", "paper", "ink", "stationery", "office supplies"],
}


def _classify(description: str) -> str:
    lower = description.lower()
    for category, keywords in CATEGORY_KEYWORDS.items():
        if any(kw in lower for kw in keywords):
            return category
    return "other"


def _extract_amount(raw_amount: str) -> float | None:
    cleaned = re.sub(r"[^\d.,]", "", raw_amount)
    cleaned = cleaned.replace(",", "")
    try:
        return round(float(cleaned), 2)
    except ValueError:
        return None


def _extract_vendor(description: str) -> str:
    parts = description.split(" - ")
    if len(parts) >= 2:
        return parts[0].strip()
    parts = description.split(" from ")
    if len(parts) >= 2:
        return parts[-1].strip()
    words = description.split()
    if len(words) >= 2:
        return " ".join(words[:2])
    return "Unknown"


def _validate_payload(payload: dict[str, Any]) -> tuple[int, str, str] | None:
    invoice_id = payload.get("invoice_id")
    description = payload.get("description")
    raw_amount = payload.get("raw_amount")

    if not isinstance(invoice_id, int):
        return None
    if not isinstance(description, str) or not description.strip():
        return None
    if not isinstance(raw_amount, str) or not raw_amount.strip():
        return None

    return invoice_id, description, raw_amount


def main(req: func.HttpRequest) -> func.HttpResponse:
    try:
        payload = req.get_json()
    except ValueError:
        return _json_error(400, "INVALID_JSON", "Request body must be valid JSON.")

    if not isinstance(payload, dict):
        return _json_error(400, "INVALID_PAYLOAD", "Expected a JSON object.")

    validated = _validate_payload(payload)
    if validated is None:
        return _json_error(
            400,
            "MISSING_FIELDS",
            "Required: invoice_id (int), description (string), raw_amount (string).",
        )

    invoice_id, description, raw_amount = validated

    amount = _extract_amount(raw_amount)
    if amount is None:
        return _json_error(
            400, "INVALID_AMOUNT", f"Could not parse amount from: {raw_amount}"
        )

    category = _classify(description)
    vendor = _extract_vendor(description)

    result = {
        "invoice_id": invoice_id,
        "vendor": vendor,
        "category": category,
        "amount": amount,
        "currency": "USD",
        "requires_approval": amount > 10000,
        "confidence": 0.92,
    }

    return func.HttpResponse(
        json.dumps(result),
        status_code=200,
        mimetype="application/json",
    )
