---
name: supervision-levels
description: Who is on which lawyer level at Monaco Solicitors and who manages or supervises them. Use when asked "who is my manager", "who supervises X", "who are my direct reports", "what level am I", "who is on Level 4", about the supervision levels or the lawyer framework, or before flagging something about a lawyer to their manager.
---

# Supervision levels

The firm's lawyers sit on four levels. The source of truth is the **Supervision levels
dashboard**: https://n8n.monacosolicitors.co.uk/webhook/supervision (sign in with your
@monacosolicitors.co.uk email and a code). Everyone can view it. Only the editors named on
the dashboard can change it.

| Level | Who | Relationship |
|---|---|---|
| 1 | Senior solicitors | **managed** (performance, ad-hoc requests) |
| 2 | about 3 years | **managed** |
| 3 | about 9 months | **managed** |
| 4 | newest, about 6 months | **supervised**: close supervision at the start |

So for Levels 1 to 3 the person above someone is their **manager**; for Level 4 it is their
**supervisor**. Use the word the data gives you (`relationship`), not "supervisor" for
everyone.

## How to look it up

A read-only copy lives in the firm's main Supabase project, table `supervision_levels`. It is
rewritten every time someone changes the dashboard and every weekday at 09:00.

**Which call you make depends on how your own "Your access" section says you reach Supabase.**
There are two routes, and the other one will simply refuse you — that is your role, not a
fault, so do not retry it the other way round.

**If your access says Supabase is "direct REST, key auto-injected":**

```
curl "https://jdjxlczkggckdnpeluuw.supabase.co/rest/v1/supervision_levels?select=name,email,title,level,level_duration,relationship,manager_name,manager_email&order=level,name"
```

Filter with PostgREST, e.g. `&email=eq.<their email>` for one person, or
`&manager_email=eq.<email>` for someone's direct reports.

**If your access says Supabase is "SQL via the read-only DB gateway":** the REST host is not
open to you and the same data is one SQL query away.

```
curl -s -X POST http://10.89.2.1:10256/query \
  -H "Authorization: Bearer $(cat ~/.claude/dbread.token)" \
  -H 'Content-Type: application/json' \
  -d '{"sql":"select name, email, title, level, level_duration, relationship, manager_name, manager_email from supervision_levels order by level, name"}'
```

For one person, keep the value out of the SQL: `{"sql":"select ... from supervision_levels
where email = $1","params":["someone@monacosolicitors.co.uk"]}`. For their direct reports,
filter on `manager_email` the same way.

**If your access section has no Supabase line at all:** you cannot read this table, and
nothing you can call will change that. Say so and give the person the dashboard link above —
they can open it themselves. Never infer somebody's manager from Pipedrive, from a mailbox,
or from the shape of the firm.

## Reading it honestly

- Only legal team members who are on a level appear. Someone missing is either not in the
  legal team or not allocated yet: say so, and point to the dashboard.
- Never write to this table, by either route. The gateway refuses writes outright, and on the
  REST route you would be editing the copy rather than the source. Changes are made in the
  dashboard by its editors.
- The copy is as fresh as the last dashboard change or this morning's 09:00 refresh. When the
  answer decides something that matters — who approves, who is told — say when the data was
  written (`updated_at`) or send the person to the dashboard.
