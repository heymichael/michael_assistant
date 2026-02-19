---
name: food_logger
description: Appends food entries to a Google Sheet using gog CLI.
---

# Food Logger Skill
This skill does not define a new tool. It provides the canonical command to run via OpenClaw host execution (Exec/system.run). If host execution is disabled, the agent should report that it cannont log.

## Action: Log one meal row

### Parameters
- `date`: YYYY-MM-DD
- `time`: HH:MM
- `meal`: Breakfast, Lunch, Dinner, or Snack
- `type`: home-cooked, delivery, or restaurant
- `description`: Brief description
- `calories`, `fat`, `carbs`, `sugar`, `fiber`, `protein`, `rounds`: numbers
- `timezone`: Local time zone


### Shell command (run exactly as written)

- Never use placeholders like `<sheet_id>` or `<range>`.
- Always use the exact spreadsheet ID and range shown below.
- Values must be passed via `--values-json` as a 2D array (row), not as an object.
- Do not use any `--date/--time/...` flags.
- Do not pass values positionally.
- Always include: spreadsheet id + range + --values-json + --insert INSERT_ROWS.
> ⚠️ Do **not** use flags like `--date`, `--time`, etc.  
> ⚠️ Do **not** invent subcommands like `gog add` or `gog append`.  


```bash
/opt/homebrew/bin/gog sheets append 1G_Vupq2nxYe6lIySuItTMIjo8V5HZFLYbTU3O54R1Kw 'Sheet1!A:M' --values-json "[[\"$date\",\"$time\",\"$meal\",\"$type\",\"$description\",$calories,$fat,$carbs,$sugar,$fiber,$protein,\"$timezone\",$rounds]]" --insert INSERT_ROWS
```




