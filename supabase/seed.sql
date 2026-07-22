-- Dev seed — LOCAL Supabase only (supabase/config.toml [db.seed] points here; also runnable
-- directly via scripts/setup-dev.sh). Idempotent: every insert is ON CONFLICT DO NOTHING keyed
-- on fixed UUIDs, so re-running produces the same state.
--
-- Seeded users (also listed in .agents/seed-users.json for scripts/agents):
--   dev@vo-cal.test    11111111-1111-1111-1111-111111111111  — 3 weeks of varied meal history
--   fresh@vo-cal.test  22222222-2222-2222-2222-222222222222  — clean slate (onboarding flows)
--
-- The history is deliberately varied so /today, /meals/summary (certainty), and the check-in
-- nudges have real texture: weighed high-certainty meals, vague low-certainty ones ("pasta"),
-- skipped breakfasts, a Sunday prep day, water logs.

-- ---------------------------------------------------------------------------
-- Auth identities (local GoTrue). Password for BOTH users: vocal-dev-password
-- (crypt() with gen_salt('bf') — pgcrypto ships enabled in local Supabase).
-- ---------------------------------------------------------------------------
INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data
)
VALUES
    ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'dev@vo-cal.test',
     crypt('vocal-dev-password', gen_salt('bf')),
     now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}'),
    ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000',
     'authenticated', 'authenticated', 'fresh@vo-cal.test',
     crypt('vocal-dev-password', gen_salt('bf')),
     now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Profile + active protocol for the seasoned user (matches the IP worked example:
-- male / 70in / 200lb / Moderate / 20% -> 1805 kcal, protein 163, fat 54, carbs 167).
-- ---------------------------------------------------------------------------
INSERT INTO public.profiles (id, tz)
VALUES ('11111111-1111-1111-1111-111111111111', 'America/New_York')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.intake_responses (id, user_id, version, answers)
VALUES ('aaaa1111-0000-4000-8000-000000000001',
        '11111111-1111-1111-1111-111111111111', 1,
        '{"age": 30, "sex": "male", "height_in": 70.0, "weight_lb": 200.0,
          "goal": "cut", "work": "desk", "train": "moderate", "kids": false,
          "med": "none", "stress": "moderate", "meals_per_day": 3}')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.protocols (id, user_id, version, active, targets, whys)
VALUES ('bbbb1111-0000-4000-8000-000000000001',
        '11111111-1111-1111-1111-111111111111', 1, true,
        '{"version": 1, "kcal": 1805, "protein": 163, "protein_min": 131, "protein_max": 163,
          "carbs": 167, "fat": 54, "fiber": 32, "water_oz": 100, "produce_servings": 6,
          "meals_per_day": 3, "whys": {}}',
        '{}')
ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Three weeks of meal history for dev@vo-cal.test. Shapes mirror what MealsStore
-- writes (items = ConfirmedItem dicts). Mix: weighed/high-certainty, vague/low-
-- certainty, skipped breakfasts (no breakfast rows some days), Sunday meal prep.
-- Times are UTC; the profile tz is America/New_York.
-- ---------------------------------------------------------------------------
INSERT INTO public.meal_logs
    (id, user_id, client_meal_id, name, meal_type, items, totals, confidence, logged_at)
SELECT
    md5('seed-meal' || d || '-' || slot)::uuid,
    '11111111-1111-1111-1111-111111111111',
    'seed-' || d || '-' || slot,
    CASE slot WHEN 1 THEN 'Breakfast' WHEN 2 THEN 'Lunch' ELSE 'Dinner' END,
    CASE slot WHEN 1 THEN 'breakfast' WHEN 2 THEN 'lunch' ELSE 'dinner' END,
    CASE
      -- Sunday (d % 7 = 0): meal-prep dinner, weighed, high certainty.
      WHEN slot = 3 AND d % 7 = 0 THEN
        '[{"name":"chicken breast","amount":180,"unit":"g","state":"cooked","fat_ratio":null,
           "brand":null,"prep_method":"grilled","variant":null,"grams":180,
           "macros":{"kcal":297,"protein":56,"carbs":0,"fat":6.5,"fiber":0},
           "confidence":0.95,"source":"dictionary","is_estimate":false},
          {"name":"white rice","amount":200,"unit":"g","state":"cooked","fat_ratio":null,
           "brand":null,"prep_method":null,"variant":null,"grams":200,
           "macros":{"kcal":260,"protein":5.4,"carbs":56,"fat":0.6,"fiber":0.8},
           "confidence":0.95,"source":"dictionary","is_estimate":false}]'::jsonb
      -- Stress-y vague dinner every 5th day: "pasta", nothing else said (low certainty).
      WHEN slot = 3 AND d % 5 = 0 THEN
        '[{"name":"pasta","amount":null,"unit":null,"state":"unspecified","fat_ratio":null,
           "brand":null,"prep_method":null,"variant":null,"grams":200,
           "macros":{"kcal":316,"protein":11.6,"carbs":61.6,"fat":1.9,"fiber":3.6},
           "confidence":0.55,"source":"dictionary","is_estimate":false}]'::jsonb
      WHEN slot = 2 THEN
        '[{"name":"turkey sandwich","amount":null,"unit":null,"state":"unspecified","fat_ratio":null,
           "brand":null,"prep_method":null,"variant":null,"grams":230,
           "macros":{"kcal":330,"protein":22,"carbs":41,"fat":9,"fiber":3},
           "confidence":0.6,"source":"dictionary","is_estimate":false},
          {"name":"grapes","amount":null,"unit":null,"state":"unspecified","fat_ratio":null,
           "brand":null,"prep_method":null,"variant":null,"grams":92,
           "macros":{"kcal":64,"protein":0.6,"carbs":16.6,"fat":0.1,"fiber":0.8},
           "confidence":0.6,"source":"dictionary","is_estimate":false}]'::jsonb
      ELSE
        '[{"name":"greek yogurt","amount":170,"unit":"g","state":"unspecified","fat_ratio":null,
           "brand":null,"prep_method":null,"variant":null,"grams":170,
           "macros":{"kcal":100,"protein":17.3,"carbs":6.1,"fat":0.7,"fiber":0},
           "confidence":0.9,"source":"dictionary","is_estimate":false},
          {"name":"granola bar","amount":1,"unit":null,"state":"unspecified","fat_ratio":null,
           "brand":null,"prep_method":null,"variant":null,"grams":40,
           "macros":{"kcal":190,"protein":3,"carbs":29,"fat":7,"fiber":2},
           "confidence":0.8,"source":"dictionary","is_estimate":false}]'::jsonb
    END,
    CASE
      WHEN slot = 3 AND d % 7 = 0 THEN '{"kcal":557,"protein":61.4,"carbs":56,"fat":7.1,"fiber":0.8}'::jsonb
      WHEN slot = 3 AND d % 5 = 0 THEN '{"kcal":316,"protein":11.6,"carbs":61.6,"fat":1.9,"fiber":3.6}'::jsonb
      WHEN slot = 2 THEN '{"kcal":394,"protein":22.6,"carbs":57.6,"fat":9.1,"fiber":3.8}'::jsonb
      ELSE '{"kcal":290,"protein":20.3,"carbs":35.1,"fat":7.7,"fiber":2}'::jsonb
    END,
    CASE WHEN slot = 3 AND d % 7 = 0 THEN 0.95 WHEN slot = 3 AND d % 5 = 0 THEN 0.55 ELSE 0.72 END,
    (now() - (d || ' days')::interval)::date
      + CASE slot WHEN 1 THEN interval '12 hours' WHEN 2 THEN interval '17 hours' ELSE interval '23 hours' END
FROM generate_series(1, 21) AS d, generate_series(1, 3) AS slot
-- Skipped breakfasts: no breakfast row on ~every 3rd day (the "skipped breakfast" pattern).
WHERE NOT (slot = 1 AND d % 3 = 0)
ON CONFLICT (id) DO NOTHING;

-- Water history (about half the target most days).
INSERT INTO public.water_logs (id, user_id, client_water_id, amount_oz, logged_at)
SELECT
    md5('seed-water' || d)::uuid,
    '11111111-1111-1111-1111-111111111111',
    'seed-water-' || d,
    48 + (d % 3) * 16,
    (now() - (d || ' days')::interval)::date + interval '20 hours'
FROM generate_series(1, 21) AS d
ON CONFLICT (id) DO NOTHING;
