# Match originals to forwarded copies by Message-ID

The secondary mailbox is dedicated to mail automatically forwarded from the primary mailbox, and the existing forwarding setup preserves the `Message-ID` header. ReadRelay uses that shared header to correlate individual messages across mailboxes because subject and sender can repeat across unrelated messages.

ReadRelay changes a copy's read status only when the match is unambiguous. It reports missing identifiers and multiple possible matches for review.

Each forwarding filter also applies a `ReadRelay` label to the original in the primary mailbox. ReadRelay lists those originals by label because Gmail's metadata scope supports label filtering while limiting access to headers and labels. Before the five-day dry run, the known seeded originals can receive the same label so they follow the live matching path.
