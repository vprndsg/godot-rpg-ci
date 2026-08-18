---
name: create-quest
description: Use when writing or editing conversations, branching dialogue, quests, errands, or anything driven by game flags — or when a request mentions dialogue/*.json, choices, "remembers", "after you talk to", or a multi-step task spanning several NPCs. Covers the dialogue graph format, flags, and how a quest is assembled.
---

# Conversations and quests

A conversation is a node graph in `dialogue/<id>.json`. A quest is nothing more
than several conversations reading and writing the same flags. There is no
quest system to register with.

## The graph

```json
{
  "id": "harbormaster",
  "speaker_default": "Kesk",
  "start": "open",
  "nodes": {
    "open": {
      "goto_if": [
        { "requires": { "ledger_paid": true }, "next": "after_paid" },
        { "requires": { "ledger_started": true }, "next": "nag" }
      ],
      "speaker": "Kesk",
      "text": "Tide's out and my paperwork isn't.",
      "next": "offer"
    },
    "offer": {
      "text": "Walk this up to Mira for me?",
      "choices": [
        { "text": "I'll do it.", "next": "accept", "set": { "ledger_started": true } },
        { "text": "Not today.", "next": "" }
      ]
    },
    "accept": { "text": "Good. Tell her Kesk sent you.", "next": "" }
  }
}
```

Per node:

- `text` — the line shown. `speaker` overrides `speaker_default`.
- `next` — the node to go to when the player presses interact. `""` or absent
  ends the conversation.
- `choices` — an array of `{ text, next, requires?, set? }`. When present, the
  player picks instead of advancing. A choice with `"next": ""` ends it.
- `set` — flags written when the node (or choice) is taken.
- `goto_if` — evaluated **before** the node's own text, in order. The first
  rule whose `requires` matches wins and the node's text never shows. This is
  how one NPC greets you differently after you have done something.
- `requires` — `"flag_name"`, or `{ "flag": true }`, or an array of either
  (all must match). Absent means always.

Flags live in `GameState.flags` and are saved with the game. Name them
`snake_case` after the thing that happened: `ledger_started`, `met_mira`.

## Building a quest

A quest is a flag moving through the world. Decide the flags first, then write
the conversations around them.

The ledger errand in this repo, as a worked example:

| Flag | Set by | Read by |
| --- | --- | --- |
| `ledger_started` | Kesk, when you accept | Kesk (nag), Mira (hand it over), Odd (comments) |
| `ledger_signed` | Mira, when you give her the ledger | Kesk (pay out), Mira (reminds you to go back) |
| `ledger_paid` | Kesk, when he pays | everyone, for the after-state |

Each step is a `goto_if` at the top of that NPC's `open` node, ordered
**latest state first** — the most advanced rule has to be checked before the
earlier ones or it will never fire.

Give the other NPCs in the room a one-line reaction to the flags. It costs
three lines of JSON and is the difference between a world and a menu.

## Rules the validator holds you to

`tools/ci.sh test -- --only dialogue` reports these by node name:

- `start` must exist, and every `next` must land on a node that exists.
- Every node must be reachable from `start`. An orphan is almost always a typo
  in a `next` somewhere else.
- **Every node must be able to reach an ending.** A hub node whose options all
  loop back traps the player forever. Give every menu a "Nothing, thanks"
  choice with `"next": ""`.
- Every node needs `text`, unless it exists only to `goto_if` elsewhere.
- Every choice needs `text`.
- **Every flag set by a conversation must be read by one.** A flag nothing
  checks means you wired half a quest. If the reader is game code rather than
  dialogue, that check will fail — read it in a `goto_if` too, or adjust the
  test deliberately.
- No placeholder text: `TODO`, `TBD`, `lorem ipsum`, `XXX`.

## Voice

Terse and dry. People here are working and tired. One or two sentences a line.
Give them an opinion about something small and specific rather than lore.
No "brave adventurer", no exposition dumps, no exclamation marks.

Compare:

> Greetings, traveller! I have an important task for you!

against what is actually in the repo:

> Tide's out and my paperwork isn't. You look like someone with functioning legs.

## Finish with

```
tools/ci.sh test
```
