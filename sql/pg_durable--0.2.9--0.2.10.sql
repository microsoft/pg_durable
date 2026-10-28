-- Copyright (c) Microsoft Corporation.
-- Licensed under the PostgreSQL License.

CREATE INDEX idx_instances_submitted_by ON df.instances(submitted_by, id);
