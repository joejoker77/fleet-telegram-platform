---
name: chase-draft
description: Draft a chaser to the other side or to a client, in the fee earner's own voice, from the matter's email history. Use when asked to "draft a chaser", "chase them", "follow up on" a deal, or to nudge an employer's solicitor who has gone quiet.
---

# Draft a chaser

## Work out what is actually being chased

```
~/work/bin/deal-brief <deal-id> --mail 12
```

From that, establish four things and state them back before drafting:

- Who owes whom a reply, and since when. Count the working days.
- What was asked. Quote it.
- Whether a deadline sits behind it: an offer's response date, an ACAS or ET1
  limitation date, a tribunal direction.
- Whether this is the first chaser or the third. The third one reads differently.

If the last email out was ours and it is four days old, say so and ask whether
they really want to chase yet.

## Match the fee earner's own voice

Do not invent a house style. Read what they actually send:

```
~/work/bin/deal-brief <deal-id> --json
```

Better, look across matters. Pull the last few chasers this fee earner sent on
similar matters and copy the register: how they open, whether they use the
recipient's first name, how they ask, how they sign off. Some are brisk and some
are warm. Reproduce theirs, not a generic one.

## The draft itself

- Subject line continues the existing thread; do not start a new one.
- Three short paragraphs at most. A chaser that explains itself at length reads
  as apologetic.
- One clear ask with a date on it.
- No "I hope this email finds you well". No "just circling back". No "I wanted
  to follow up regarding". Open with the substance.
- Client-facing chasers explain what happens next. Solicitor-facing ones do not.

## Then stop

Show the draft. Do not send it. Say what it is going to, and wait for the fee
earner to say send. If they do ask you to send it, show the recipient address
and the subject line one more time first.
