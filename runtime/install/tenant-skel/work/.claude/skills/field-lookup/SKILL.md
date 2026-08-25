---
name: field-lookup
description: Resolve Pipedrive's 40-character field hashes to names and back before writing any CRM query, and get the option ids behind dropdown fields. Use whenever a query is being written against a custom field, a hash turns up in an export, a filter returns nothing, or someone asks what a field is called.
---

# Resolve the field before you trust the answer

Pipedrive holds **311 fields on a deal and 254 of them are named by a
40-character hash.** A query written against the wrong one returns a confident
empty answer, not an error. That is the failure this prevents, and it is silent.

## Look

```
~/work/bin/field-map limitation           # name fragment -> hashes
~/work/bin/field-map 4ceb2fc3...          # hash -> what it is
~/work/bin/field-map --options <field>    # the ids behind a dropdown
~/work/bin/field-map --entity person email
~/work/bin/field-map --all                # every custom field on a deal
~/work/bin/field-map --tables             # the Supabase tables, to cross-check
```

## Dropdowns are the trap worth knowing

An enum field stores the **option id**, never the label. So:

```
4ceb2fc3...  enum  NWNF Terms + Timeline
                     755 = 35% inc VAT
                     756 = 30% inc VAT
                     757 = 25% inc VAT
```

Filtering on `"30% inc VAT"` matches nothing and reports nothing wrong. You need
`756`. Run `--options` before writing any filter on a dropdown, every time.

## Similar names are not the same field

Search ACAS and seven fields come back, four of them dates and three storing a
date in a plain text box. There is no way to guess which one a report should
use. Show the candidates and say which you picked and why, rather than choosing
one silently.

## Use it before, not after

The point is to run this **before** the query, not to explain an empty result
afterwards. If a report comes back with zero rows, resolving the field is the
first check, ahead of assuming the data is not there.

When handing a hash to someone else, give the name alongside it. A bare hash in
a message is unreadable a week later.
