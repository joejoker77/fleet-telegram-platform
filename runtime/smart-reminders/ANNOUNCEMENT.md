# Smart reminders: what they are and how to use them

*For everyone with a Claude assistant on Telegram. Launched 5 October 2026.*

## The one-paragraph version

Your assistant can now come back to something later on its own. Tell it "remind me on the 20th to chase this", "check this matter again in two weeks and tell me what changed", or "every Monday at 8:30 go through my deadlines and tell me what needs doing", and it will schedule that for you. At the set time your assistant wakes up in your Telegram chat, does the work with everything it knows, and writes to you. You do not have to remember to ask.

## How to ask

Say **"smart reminder"** and then what you want, in plain words, in your Telegram chat or in the Claude app. Examples:

- "Smart reminder: on Friday at 9, remind me to call the client on deal 181017."
- "Smart reminder for the 13th: check whether the other side has replied on this matter and tell me."
- "Smart reminder every Monday at 8:30: look at my matters that have gone quiet and give me the list."
- "Smart reminder in two weeks: re-run the numbers you just gave me and tell me if anything moved."
- "Smart reminder on the 1st of every quarter: pull my billing for the quarter and send me the summary."

Your assistant writes itself a note for the future (what to do, how it did it last time, what to compare against) and schedules it. You get a one-line confirmation. **The result always arrives in your main Telegram chat**, even if you set the reminder from the Claude app. Times are London time.

To see what is scheduled: "what reminders do I have?". To cancel: "remove the Monday deadlines reminder".

## What happens when it fires

Your assistant receives the note at the scheduled time and treats it as a request from you. It does the work and replies in your chat as usual. If you are mid-conversation at that moment, the reminder waits its turn.

## The safety check

Every new reminder is checked automatically before it is created. The check reads the prompt and the last few things you said, and asks: could this send client or personal data outside the firm, touch credentials, message clients or outsiders on a schedule, or do something destructive unattended? Normal follow-ups pass straight through and you are told "created".

If the check is not sure, the reminder is not created yet. Your assistant tells you it has gone to the tech team for approval. They get it in Slack with Approve and Decline buttons; whichever they press, your assistant tells you the outcome. Nothing runs in the meantime. Please do not try to rephrase a flagged request to get round the check; ask the tech team instead.

## What it is not for

- Anything that calls an outside AI service on a timer. That stays banned; this runs on the firm's own Claude.
- Sending things to clients or the other side automatically. Your assistant can prepare them; you send them.
- Replacing your diary for court or tribunal deadlines. Use it as a second pair of eyes, not the only one.

## Questions

Tech team: Tom Macaluso. Policy: Dmitrii Rudenko.
