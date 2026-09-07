---
name: send-for-signature
description: Send a settlement agreement to a client for e-signature through PandaDoc. Use when asked to "send this SA for signature", "get this signed", "send the settlement agreement to the client to sign", or when a fee earner attaches an unsigned agreement and names a client or a deal number.
---

# Send a settlement agreement for signature

The agreement comes from the other side as a flat PDF. Nothing in it can be
signed electronically until fields are put on it, and no two of them lay the
execution page out the same way. So this runs in three steps and the fee
earner picks the lines. You never pick them.

## Before anything else

```
~/work/bin/sa-sign check
```

That tests the handoff end to end and prints which of the two routes this pod
will use. If it fails, stop and pass on what it printed.

**Why there is a handoff at all.** PandaDoc will not take an upload. The
`documents_create` tool wants a URL it can fetch the PDF from, so the tagged
file has to sit somewhere reachable for the minute or two that takes. There are
two places it can sit and `check` works out which you have:

- **The firm's own storage.** A private bucket, a signed link that expires in
  fifteen minutes, nothing public at any point. Better, and used where it works.
- **Your own Monaco Google Drive.** A folder called `esign-handoff`, a file with
  a 32-character random name that says nothing about the client, readable by
  link until you revoke it. Used on a pod that cannot write to the firm's
  storage, which is most fee earners.

Most fee earners are on the Drive route and have to connect Google Drive once:

```
composio-connect --toolkit googledrive --user-id <their telegram chat id>
```

Send them the link it prints. They sign in once, to their own Monaco account,
and it is never asked again. The tool also needs that same chat id to know
whose Drive to use; pass `--composio-user <chat-id>` the first time and it
remembers.

**Google asks twice and the second screen is the one that matters.** The first
is sign-in, the second grants access to their Drive. Stopping after the first
still records the account as connected, and every call then comes back "403
insufficient authentication scopes". Two of the twenty lawyers checked on
1 Sep were in exactly that state. If `check` says the account is signed in but
was never given file access, the fix is to run `composio-connect` again and say
yes to both screens; the old connection can be left where it is.

Connecting twice is fine. Where a lawyer has two Google accounts on the same
Drive the tool picks the Monaco one by itself, and only stops if there are two
different Monaco addresses to choose between.

On the Drive route the copy has no expiry, so `revoke` is not tidying up, it is
the thing that ends the exposure. Run it. It deletes the file outright and then
fetches the link to prove it is dead, because trashing a Drive file leaves it
serving downloads for another thirty days.

There is no API key in this. PandaDoc is reached through the Claude
integration, using the `mcp__PandaDoc__*` tools. `sa-sign` does the parts
those tools cannot: reading the PDF, placing the fields, handing the file over
and cleaning up after.

## 1. Scan

You need the PDF, and the client. Take the deal id if they gave you one; the
client's name and email come off the matter, so nobody types an address.

```
~/work/bin/sa-sign scan <pdf> --deal <deal-id>
```

If the adviser's certificate is going out in the same envelope, add
`--adviser-email` and `--adviser-name` for whoever advised.

This writes a plan and renders each page that has signature lines, with every
candidate line boxed and numbered. **Read those images yourself** before you
say anything: they are the whole point of the step.

Then tell the fee earner what is on the page. Name the lines by their
reference (`p12#0`), say what each one appears to be and who it appears to
belong to, and ask which is the client's signature. The `looks like` column is
a hint from the nearest label and it is wrong about as often as it is right,
so offer it as a reading of the page, never as a finding.

If the scan says the document reads as a deed, stop there. A deed needs a
witness watching the signature. It gets signed in the room, not by email.

## 2. Prepare

Once they have picked:

```
~/work/bin/sa-sign prepare --plan <plan.json> --sign p12#0 --date p12#1
```

Add `--name pN#K` for a line that wants the signer's printed name; it is
filled in from the deal. A date line is filled with today's date unless you
pass `--no-fill-date`. Put `@adviser` on the end of a reference for a line on
the adviser's certificate: `--sign 'p12#2@adviser'`.

The employer's signature never goes in our envelope. They sign their own copy.
Putting their block in ours is how the wrong person ends up on the wrong line.

This stamps the fields and renders the pages again. **Read those images too**,
and tell the fee earner what landed where and what was pre-filled.

## 3. Publish

Only after they have seen the check images and said yes. Set `"confirmed":
true` in the plan, then:

```
~/work/bin/sa-sign publish --plan <plan.json>
```

This puts the tagged PDF wherever this pod can reach, by whichever of the two
routes above applies, and prints a ready `documents_create_request`. The output
names the route it used. Add `--via drive` or `--via supabase` to force one.

## 4. Create, then send

Pass that request object straight to `mcp__PandaDoc__documents_create`. Change
nothing in it.

Creation is asynchronous. Poll `mcp__PandaDoc__documents_status_get` until the
status is `Draft`. Then call `mcp__PandaDoc__documents_details_get` and check
two things before you send anything:

- there is a field of type `signature`, and
- its `assigned_to.recipient_type` is `signer`, not `CC`.

If `fields` comes back empty the tags did not parse, and the client would get a
document they cannot sign. Do not send it. Say so.

Then `mcp__PandaDoc__documents_send` with a subject and a short message.

## 5. Clean up and record

```
~/work/bin/sa-sign revoke --plan <plan.json>
~/work/bin/sa-sign note   --plan <plan.json> --doc <document-id>
```

`revoke` deletes the published copy; run it even if the send failed, and run it
as soon as PandaDoc reaches Draft rather than waiting until the end. On the
Drive route it is the only thing that closes the link. If it reports a problem,
say so plainly and tell Tom: the agreement is still sitting there readable.
`note` puts the record on the Pipedrive deal. Report the document id back.
`sa-sign status <id>` says where it has got to afterwards.

If a session dies partway and nobody revoked anything:

```
~/work/bin/sa-sign sweep            # what is still shared
~/work/bin/sa-sign sweep --revoke   # delete it
```

`sweep` only ever touches files it uploaded itself, which it knows by their
random name. Anything with a name a person would recognise is listed and left
alone, so it cannot delete a real document even if one is in that folder.

## Two things about the agreement itself

**Do not choose the file.** The same agreement recurs three or four times down
an email thread as it is renegotiated, and one deal at the signing stage held
a COT3. Ask which attachment. `~/work/bin/pd-attachments list <deal-id>` gives
you the list to offer.

**The advice comes first.** The signing invite must not go out before the
adviser has advised the client and that advice is recorded. Check that on the
matter before sending, and say so if it is missing.

## Field tags, if you ever hand-build one

Curly braces, long type names, and every optId declared in `fields`:

```
{signature:client:clientsig1______}
{date:client:clientdate1____}
{text:client:clientname1____}
```

Square brackets upload as ordinary text and the client gets a document with
nothing to sign, which is exactly what PandaDoc's own documentation will lead
you to. Miss one optId out of `fields` and creation fails outright. Dates go in
ISO. `sa-sign prepare` already gets all of this right.

## Do not

- Do not decide which line is the client's signature. Show the page, ask.
- Do not send a deed.
- Do not send without the fee earner seeing the check images.
- Do not send without checking the signature field exists and is assigned.
- Do not leave the published copy behind. Always `revoke`.
- Do not pad the reply with a summary of the steps you just ran.
