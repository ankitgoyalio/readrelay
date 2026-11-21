# Keep primary Gmail access on the Mac mini

Dot connects only to the secondary mailbox so the user can choose which messages it receives through Gmail forwarding filters. ReadRelay runs on the Mac mini with `gmail.metadata` for the primary mailbox to observe read status and match message headers, and `gmail.modify` for the secondary mailbox to clear unread status on matched forwarded copies. The primary grant covers mailbox-wide labels and headers and excludes message bodies.
