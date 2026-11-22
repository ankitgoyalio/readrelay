# Use Homebrew for the background service lifecycle

Distribute the Apple silicon macOS beta as a versioned CLI build through GitHub Releases and a project-owned Homebrew tap. Homebrew manages the per-user `launchd` job, so users can start it, stop it, and register it at login through the same tool they use to install ReadRelay. The job runs on load and then polls every 15 minutes while the Mac is awake and the user is logged in.

ReadRelay owns mailbox setup, sync health, and the approval to mark forwarded copies as read. Users can preview before verifying forwarding. Write approval requires a known test message with a labeled original and exactly one matching forwarded copy. Approval covers the reviewed five-day backlog and future eligible messages for the same mailbox pair and primary label. Changing either requires a new preview and approval. Stopping the Homebrew service preserves pending work and approval. Revoking approval in ReadRelay returns the job to preview mode.

The beta supports one mailbox pair per macOS login and focuses on fresh installations. Each user supplies one Google Desktop OAuth client file and authorizes the two mailbox accounts separately. This lets us test a self-serve release without operating a shared Google OAuth project.

The beta guide will recommend a user-owned External project set to In production once a fresh install confirms both grants still work unattended past day seven. Testing is the fallback, with its seven-day expiry explained in the guide. If either account needs reauthorization, ReadRelay keeps the saved state and resumes the approved mode after verifying the same mailbox and its required scope.
