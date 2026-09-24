# Food sources, measured

Truth: 210 curated dictionary foods (kcal per 100 g). Agreement = within 15 percent.
FatSecret refused 5 of 210 lookups after every retry (error 21: this IP not yet allowed on that edge node); its columns count the 205 it answered.

| Source | Found | Agree with the curated number | Serving grams | Cups/pieces | Latency p50 / p95 ms |
|---|---|---|---|---|---|
| FatSecret | 198/205 | 135/205 | 197/205 | 166/205 | 101 / 10950 |
| USDA FDC | 157/210 | 61/210 | 0/210 (per-100 g rows only) | 0/210 | 1267 / 4002 |

## Where they disagree with the curated number

| Food | Curated | FatSecret | USDA |
|---|---|---|---|
| ground beef 70/30 | 279 | 332 | miss |
| ground beef 90/10 | 214 | 135 | miss |
| ground beef 93/7 | 190 | 141 | miss |
| ground beef 96/4 | 165 | 134 | miss |
| ground beef | 240 | 276 | 198 |
| ground turkey 93/7 | 213 | 143 | miss |
| ground turkey 99/1 | 151 | 233 | miss |
| ground turkey | 213 | 233 | 0 |
| ground chicken | 189 | 237 | 0 |
| ground pork | 297 | 263 | 0 |
| chicken breast | 165 | 195 | miss |
| chicken thigh | 209 | 245 | 0 |
| chicken wing | 203 | 288 | miss |
| rotisserie chicken | 190 | refused | 378 |
| turkey breast | 135 | 109 | 106 |
| egg | 143 | 147 | 55 |
| whole milk | 61 | 60 | 157 |
| skim milk | 34 | 38 | 56 |
| almond milk | 15 | 17 | 0 |
| oat milk | 47 | 48 | 0 |
| greek yogurt | 59 | 92 | miss |
| whole milk yogurt | 61 | 61 | 0 |
| butter | 717 | refused | 900 |
| mozzarella cheese | 300 | 302 | 248 |
| feta cheese | 264 | refused | 0 |
| provolone cheese | 351 | 351 | 0 |
| cheese | 390 | 350 | 295 |
| salmon | 208 | 146 | 902 |
| tuna | 132 | refused | 187 |
| cod | 105 | 211 | 902 |
| tilapia | 128 | 96 | 0 |
| shrimp | 99 | 144 | 99 |
| sardines | 208 | 208 | 902 |
| mahi mahi | 109 | 85 | 0 |
| ribeye steak | 291 | 193 | 0 |
| sirloin steak | 212 | 170 | 0 |
| bacon | 541 | 541 | 309 |
| ham | 145 | 246 | 263 |
| hot dog | 290 | 270 | 91 |
| tofu | 144 | 271 | 94 |
| jasmine rice | 130 | 329 | miss |
| white rice | 130 | 129 | 359 |
| brown rice | 123 | 110 | 365 |
| pasta | 158 | 131 | 371 |
| whole wheat pasta | 149 | 357 | 159 |
| egg noodles | 138 | 138 | 384 |
| quinoa | 120 | 143 | 0 |
| oatmeal | 71 | 62 | 269 |
| potato | 93 | 104 | 0 |
| sweet potato | 90 | 86 | 191 |
| mashed potato | 113 | 100 | 89 |
| low carb bread | 143 | 169 | miss |
| sourdough bread | 289 | 244 | 272 |
| croissant | 406 | 406 | 254 |
| pancake | 227 | 227 | 268 |
| waffle | 291 | 310 | 437 |
| mayonnaise | 680 | 390 | miss |
| light mayonnaise | 330 | 233 | 238 |
| peanut butter | 588 | 588 | 0 |
| almond butter | 614 | 633 | 0 |
| ketchup | 101 | 97 | 117 |
| salsa | 36 | 27 | 29 |
| light ranch dressing | 220 | 167 | 160 |
| italian dressing | 240 | 291 | miss |
| marinara sauce | 51 | 74 | miss |
| alfredo sauce | 180 | 410 | 535 |
| bbq sauce | 172 | 140 | miss |
| sriracha | 93 | miss | 79 |
| sour cream | 198 | 214 | 0 |
| hummus | 166 | 177 | 229 |
| black beans | 132 | 341 | miss |
| pinto beans | 143 | 176 | miss |
| kidney beans | 127 | 82 | 47 |
| chickpeas | 164 | 236 | 0 |
| lentils | 116 | 165 | 0 |
| avocado | 160 | 160 | 0 |
| burrito bowl | 120 | 136 | 161 |
| burger | 254 | 313 | 286 |
| salad | 17 | 64 | 430 |
| lettuce | 15 | 14 | 0 |
| sandwich | 250 | 304 | 494 |
| green beans | 35 | 31 | 0 |
| carrots | 41 | 41 | 341 |
| bell pepper | 31 | 26 | 0 |
| tomato | 18 | 18 | 0 |
| mushrooms | 28 | 22 | 0 |
| asparagus | 22 | 20 | 0 |
| cauliflower | 23 | 25 | 0 |
| zucchini | 17 | 16 | 0 |
| apple | 52 | 52 | 254 |
| orange | 47 | 47 | 246 |
| strawberries | 32 | 32 | 0 |
| blueberries | 57 | 57 | 0 |
| grapes | 69 | 69 | 27 |
| walnuts | 654 | 654 | 0 |
| cashews | 553 | 564 | 0 |
| chia seeds | 486 | 485 | 0 |
| protein bar | 350 | 259 | 412 |
| latte | 42 | 370 | 27 |
| beer | 43 | 43 | 29 |
| grapefruit | 42 | 32 | miss |
| raspberries | 52 | 52 | 0 |
| blackberries | 43 | 43 | 0 |
| watermelon | 30 | 30 | 0 |
| mixed fruit | 60 | 47 | 47 |
| water | 0 | miss | 19 |
| unsweetened almond milk | 15 | 7 | 0 |
| sweetened almond milk | 38 | 24 | 38 |
| fairlife milk | 49 | 58 | miss |
| fairlife 2% milk | 49 | 33 | miss |
| fairlife 1% milk | 45 | 33 | miss |
| chocolate milk | 83 | 76 | 535 |
| protein shake | 46 | 66 | 392 |
| coffee creamer | 233 | 500 | 136 |
| heavy cream | 340 | 345 | 0 |
| diet soda | 0 | 1 | 0 |
| powdered peanut butter | 500 | 385 | miss |
| avocado toast | 207 | 240 | miss |
| sushi roll | 150 | 175 | 94 |
| smoothie | 60 | 144 | 89 |
| protein smoothie | 70 | 144 | 86 |
| mac and cheese | 180 | 203 | 110 |
| rice and beans | 130 | 164 | 164 |
| chicken and rice | 150 | 160 | 51 |

## Long tail (no curated truth; read them)

| Term | FatSecret | USDA |
|---|---|---|
| spanakopita | Spanakopitta: 206 kcal/100 g, serving 1 cubic inch (12.0 g), units ['cup'] [108 ms] | Spanakopita: 212 kcal/100 g [899 ms] |
| halloumi | miss | miss |
| pierogi | Italian Pierogi: 220 kcal/100 g, serving 1 pierogi (50.0 g), units [] [100 ms] | Pierogi: 195 kcal/100 g [811 ms] |
| bison bacon | Epic Sweet & Savory Bison & Uncured Bacon: 429 kcal/100 g, serving 6 pieces (28.0 g), units ['piece'] [152 ms] | miss |
| street taco chicken | Tijuana Flats Street Taco - Classic Chicken: 145 kcal/100 g, serving 1 serving (None g), units [] [124 ms] | miss |
| beef medallions | Icon Meals Beef Medallions: 106 kcal/100 g, serving 1 container (340.0 g), units ['piece'] [149 ms] | Beef, chuck, shoulder clod, shoulder tender, medallion, separable lean and fat, trimmed to 0" fat, choice, raw: 145 kcal/100 g [1307 ms] |
| protein pancake | Protein Pancakes: 191 kcal/100 g, serving 1 pancake (45.0 g), units [] [78 ms] | miss |
| greek yogurt protein smoothie | Optimum Nutrition Greek Yogurt Protein Smoothie: 394 kcal/100 g, serving 1 scoop (33.0 g), units ['scoop'] [249 ms] | miss |
| McDonald's big mac | McDonald's Big Mac: 580 kcal/100 g, serving 1 serving (None g), units [] [84 ms] | McDONALD'S, BIG MAC: 257 kcal/100 g [1323 ms] |
| Chipotle burrito bowl | Chipotle Mexican Grill Burrito Bowl: 910 kcal/100 g, serving 1 bowl (None g), units [] [165 ms] | miss |
| Chobani greek yogurt | Chobani Green Tea Blended Greek Yogurt: 93 kcal/100 g, serving 1 container (150.0 g), units ['piece'] [171 ms] | Yogurt, Greek, Blueberry, CHOBANI: 82 kcal/100 g [1305 ms] |
| Fairlife 2% milk | Fairlife Skim Milk: 33 kcal/100 g, serving 1 cup (240.0 g), units ['cup', 'ml'] [153 ms] | Fairlife Lactose- Free 2% Milk - 52 fl oz: 50 kcal/100 g [1147 ms] |
| Quest protein bar | Quest S'mores Protein Bar: 317 kcal/100 g, serving 1 bar (60.0 g), units ['piece'] [145 ms] | miss |
| oikos triple zero | miss | miss |
| kodiak protein pancake mix | miss | miss |
| cosmic crisp apple | Cosmic Crisp Apple: 71 kcal/100 g, serving 1 apple (140.0 g), units [] [89 ms] | miss |
