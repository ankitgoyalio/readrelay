# Sync read status in one direction

ReadRelay initially covers messages forwarded by Gmail filters. It marks a matched forwarded copy as read when it observes the original message in a read state, so an original marked unread again before a sync stays eligible for a future check. Once the forwarded copy is read, marking the original unread again can serve as a reminder in the primary mailbox.

The five-day window defines the initial backlog. An eligible message that arrives after launch stays in scope even if the user first reads it much later.
