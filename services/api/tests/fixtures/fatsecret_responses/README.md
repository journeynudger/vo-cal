# FatSecret fixtures

Authored from the platform's documented response shapes on 2026-09-24, BEFORE the caller
IP was allow-listed (the first live call answered error 21). They pin the client's mapping
code, not the platform's data. `scripts/food-source-eval --record` replaces them with
recorded responses once the IP is listed; the tests read whatever is here.
