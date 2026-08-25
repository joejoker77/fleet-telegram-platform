---
name: matter-brief
description: Brief the fee earner on one matter before a call or a handover. Use when asked to "brief me on", "catch me up on", "what's happening with" a deal number or a client name, or when a matter has just landed on their desk from someone else.
---

# Brief me on this matter

## Get the facts first

Run the tool. Do not query Pipedrive by hand; the tool already knows the field
keys, the pagination and the traps.

```
~/work/bin/deal-brief <deal-id>
```

If you were given a client name rather than a number, find the deal first:

```
curl -s "https://monacosolicitors2.pipedrive.com/api/v2/deals/search?term=<name>&limit=5" | python3 -m json.tool
```

If more than one matter matches, list them with stage and last contact and ask
which one before going further.

## Then say what matters

The tool's output is the raw material, not the answer. Reply with:

1. **One sentence on where the matter stands.** Client, employer, what is being
   claimed or negotiated, and what stage it sits at.
2. **The clock.** Any limitation date, how many days away, and whether ACAS
   conciliation has started or a certificate has issued. If no date is recorded,
   say so plainly: on a tribunal claim that is a gap, not a clean sheet.
3. **The last exchange.** Who wrote last, when, and what they actually said.
   Quote the operative line rather than summarising it away.
4. **What is waiting on us.** Open tasks, undrafted documents, an unanswered
   offer, a client who asked a question that never got an answer.
5. **What you would worry about.** This is the part they cannot get from
   Pipedrive. Silence on a matter with a live deadline. An offer with a
   response date that has passed. A schedule of loss that has never been drafted.

Keep it to what fits on a phone screen. They are reading it walking into a call.

## Do not

- Do not say a document does not exist because the Files tab is empty. Email
  attachments live somewhere else; the tool lists them, and `pd-attachments`
  fetches them.
- Do not give legal advice on the merits. Set out what the file says.
- Do not pad it with a summary of what you just did.
