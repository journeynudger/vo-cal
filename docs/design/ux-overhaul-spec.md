# What the app should look and feel like (spec for the outside critic, 2026-09-25)

Vo-Cal is a voice-first calorie tracker built to Dieter Rams's principles: less, but
better; honest; unobtrusive; thorough to the last detail. Palette: cream background
#FAF9F6, cards #F4F2EE, ink #1A1A1A, muted #8A8A8E, gold accent #C4A35A, black pill
buttons. Light mode only. SF Pro. Three radii: 24 pt cards, 20 pt rows and tiles, 16 pt
chips. Spacing on a 4/8/12/16/24/32 scale. One content margin of 16 pt.

## Today

- Header: a muted date line, the title "Today" (or the weekday when browsing another day)
  at 30 pt semibold, and a 44 pt glass circle with a person glyph at the top right that
  opens Settings. Nothing sits under the status bar: a frosted strip carries the time and
  battery over scrolling content.
- Week strip: seven days as three-letter names over plain numbers; the selected day is one
  filled black circle; future days are dimmed; no rings, no dashes.
- Cards: every card starts with a 13 pt muted title, the number 8 pt below in the numeral
  face (gold for calories left, ink elsewhere), one supporting line 4 pt under it. One
  fill for every card. Completion is a small green tick beside the title and a green
  hairline, never a tinted card or a corner badge. The Calories left card may carry
  "of 2,040 today · 320 burned" when Apple Health is connected.
- Produce, Water, Fiber: three tiles of equal height with the same header, "5 / 5" in a
  15 pt semibold numeral, and one thin progress bar; the water tile carries a small gold
  plus at the top right because it alone can be tapped.
- Usuals: chips with the meal's real name and its calories.
- Logged today: rows named after what was eaten ("Greek yogurt, berries & granola"), a
  second line with the slot and time ("Lunch · 12:40 PM" or just the time), the calories
  at the trailing edge. No icons. 20 pt radius. Never "Meal 1".
- The tip card (gold hairline) appears only when nothing is logged that day.
- The bottom of the screen is the capture bar (below); content ends above it.

## The capture bar

- One frosted, translucent row at the bottom: a plus circle, a field reading "What did you
  eat?", and the mic, a 56 pt light glass circle with a gold microphone and a gold rim,
  clearly the primary control. Content behind the bar stays faintly visible through a
  gradient fade.
- Typing: the field grows up to five lines; the mic becomes the Vo-Cal mark in the same
  gold; answers from the person's history rise above the row as a frosted panel with the
  matched letters bold and calories in muted text.
- A staged photo shows as a thumbnail chip above the row with a remove badge, and the
  field reads "Add a note (optional)".

## The result

- Header: a glass close circle, the meal's name (or the slot), "N checks left" in gold
  when checks are open, the confidence badge.
- When a usual is recognized: a gold-hairline card first, "Is this your metal detox
  smoothie?", "310 cal · 3 items, as you logged it before", a black "Yes, that one" pill
  and a plain "No"; the first time, one muted line explaining that naming a meal once
  makes this happen.
- Calories card: "Calories" or "Calories so far" (never a plus sign after the number), the
  number at 48 pt.
- Check cards: the item's name, its calories at the trailing edge, a muted line with the
  amount and macros ("113 g · cooked · 25P 0C 17F"), the question in ink, and option chips
  at least 44 pt tall. Item cards without a check show name, amount, calories, macros, edit.
- The pinned bar at the bottom: a 56 pt black pill and, when checks are open, a plain
  "Log anyway (typical values)" line; about 100 pt tall including the safe area, frosted.

## First run and updates

- The tour: a 72 percent black scrim with a rounded cutout over one control at a time, a
  gold glow ring, a cream card beside it with a 17 pt title, 15 pt muted body, Back / Next
  and "N of M".
- What's New: a cream sheet, rows of a symbol, a title and a body, one black Continue pill.
- The Action button card: title, two-line body, "Open Settings" pill, "Later".
- Apple Health: a large gold flame, "Connect Apple Health", a two-line body, "Connect Apple
  Health" pill, "Not now".

Judge every render against this and against Rams: what is superfluous, unclear, cramped,
misaligned, or dishonest?
