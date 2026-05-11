-- =============================================================================
-- Demo Script — AI Pipeline Highlights (short, ~2:30 walkthrough)
-- Companion to: docs/demo-rag-pipeline-script-short.md
--
-- Paste each section in psql as you narrate. Names match the script
-- exactly (table = documents, pipeline = rag_pipeline) so copy/paste works.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- ACT 1 — RAG Pipeline in Seconds
-- ---------------------------------------------------------------------------

-- 1a. The "most boring table in the world": a product catalog.
DROP TABLE IF EXISTS documents CASCADE;
CREATE TABLE documents (
    id          SERIAL PRIMARY KEY,
    title       TEXT NOT NULL,
    content     TEXT NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 1b. Drop in five real-looking products. `title` = product name,
--     `content` = marketing description that will get chunked + embedded.
INSERT INTO documents (title, content) VALUES
    ('Sony WH-1000XM5 Wireless Headphones',
     'Premium over-ear headphones with industry-leading active noise '
     'cancellation, 30-hour battery life, multipoint Bluetooth, and '
     'crystal-clear hands-free calling. Lightweight design ideal for '
     'travel, daily commutes, and focused work sessions. '
     'The WH-1000XM5 features a newly designed integrated processor V1 '
     'that delivers exceptional noise cancellation by processing eight '
     'microphones and optimizing in real time. Two processors control '
     'eight microphones, creating the most advanced noise cancellation '
     'Sony has ever produced. Speak-to-Chat automatically pauses your '
     'music and lets in ambient sound when it detects your voice. '
     'Adaptive Sound Control learns your frequently visited locations '
     'and adjusts ambient sound settings to match. Multipoint connection '
     'lets you quickly switch between two Bluetooth devices, so you can '
     'watch a video on your laptop and instantly take a call on your '
     'phone. The soft-fit leather headband and ear pads distribute '
     'pressure evenly for all-day comfort.'),
    ('Keychron Q1 Pro Mechanical Keyboard',
     'Wireless 75% mechanical keyboard with hot-swappable switches, '
     'aluminum CNC body, double-shot PBT keycaps, QMK/VIA support, and '
     'per-key RGB. A favorite of developers who want a tactile, '
     'customizable typing experience for long coding sessions. '
     'The Q1 Pro adds wireless connectivity via Bluetooth 5.1 with up '
     'to three device connections and a 2.4GHz wireless option for '
     'ultra-low latency. The 6,000mAh battery lasts up to 300 hours '
     'in Bluetooth mode with the backlight off. Each switch socket is '
     'hot-swappable, meaning you can change switches without soldering. '
     'Full QMK and VIA compatibility lets you remap every key, create '
     'macros, and build complex layers right from your browser. The '
     'CNC-machined aluminum case weighs over 2kg, providing a rock-solid '
     'typing foundation with zero flex. A silicone dampening pad and '
     'case foam further reduce ping and hollowness for a premium, '
     'thocky sound profile favored by enthusiasts.'),
    ('Uplift V2 Standing Desk',
     'Electric height-adjustable standing desk with a 355 lb lift '
     'capacity, whisper-quiet dual motors, programmable height presets, '
     'and a solid bamboo top. Built for ergonomic home offices and '
     'long workdays at the keyboard. '
     'The V2 frame features an advanced dual-motor system that adjusts '
     'height smoothly and quietly at 1.5 inches per second, with a '
     'height range from 25.3 to 50.9 inches to accommodate users of '
     'all sizes. The keypad offers four programmable memory presets so '
     'you can switch between sitting and standing positions instantly. '
     'Anti-collision technology detects obstacles and reverses direction '
     'to prevent damage to monitors, shelves, or other objects. The desk '
     'includes a built-in wire management tray and multiple grommet '
     'options for clean cable routing. Available in over 20 desktop '
     'materials including bamboo, rubberwood, reclaimed Douglas fir, '
     'and high-pressure laminate. An industry-leading 15-year warranty '
     'covers the frame and motors.'),
    ('Logitech MX Master 3S Mouse',
     'Ergonomic wireless productivity mouse with an 8K DPI sensor, '
     'silent clicks, MagSpeed electromagnetic scrolling, and seamless '
     'multi-device switching across laptops and desktops. A staple for '
     'developers, designers, and power users. '
     'MagSpeed scrolling uses electromagnetic force instead of mechanical '
     'ratchets, allowing you to scroll through 1,000 lines per second '
     'with pixel-perfect precision. The scroll wheel automatically '
     'shifts between ratchet and free-spin modes depending on scroll '
     'speed. Quiet clicks reduce noise by 90 percent compared to the '
     'MX Master 3 while maintaining the same satisfying tactile feel. '
     'Flow cross-computer control lets you move your cursor seamlessly '
     'between up to three computers on the same network and even copy '
     'and paste text, images, and files between machines. The contoured '
     'shape supports your hand with a 57-degree vertical angle that '
     'reduces wrist strain. USB-C quick charging provides three hours '
     'of use from just one minute of charging. The full charge lasts '
     'up to 70 days on a single charge.'),
    ('Anker 737 GaNPrime 120W Charger',
     'Compact three-port USB-C and USB-A wall charger using GaN tech to '
     'deliver up to 120W total. Charges a MacBook Pro, phone, and '
     'headphones at the same time, making it perfect for travel and '
     'small desk setups. '
     'GaNPrime technology combines next-generation gallium nitride '
     'semiconductors with Anker proprietary PowerIQ 4.0 for dynamic '
     'power distribution across all three ports. The charger '
     'automatically detects connected devices and reallocates wattage '
     'in real time as you plug and unplug gadgets. ActiveShield 2.0 '
     'monitors temperature over three million times per day to prevent '
     'overheating. When using a single USB-C port, the full 120W goes '
     'to one device — enough to fast charge a 16-inch MacBook Pro. '
     'Two USB-C ports and one USB-A port handle three devices '
     'simultaneously with intelligent power splitting. The foldable '
     'plug design and compact form factor make it 43 percent smaller '
     'than the original Apple 140W charger, fitting easily into a '
     'laptop bag or travel pouch.');

-- 1c. Declare the pipeline. Read it like a sentence:
--     take `documents`, chunk the `content`, embed the chunks.
-- (Uncomment if you've created it before in this DB.)
SELECT ai.drop('rag_pipeline');
SELECT ai.drop('rag_pipeline_plus');
DROP TABLE IF EXISTS documents CASCADE;
DROP TABLE IF EXISTS rag_pipeline_output CASCADE;
DROP TABLE IF EXISTS rag_pipeline_plus_output CASCADE;
