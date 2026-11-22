import Foundation

struct MailboxAccount: Sendable {
    let role: MailboxRole
    let email: String
    let reconnectCommand: String?

    var description: String { "\(role.rawValue) mailbox (\(email))" }

    func failure(_ detail: String, nextStep: String? = nil) -> RelayError {
        RelayError("Could not access the \(description). \(detail)\(nextStep.map { " \($0)" } ?? "")")
    }

    func grantFailure(_ detail: String) -> RelayError {
        failure(detail, nextStep: reconnectCommand.map { "Run \($0)." })
    }

    func googleFailure(_ error: GoogleHTTP.Failure) -> RelayError {
        let nextStep: String
        switch error.cause {
        case .network:
            nextStep = "Check your network connection and retry."
        case .http(429, _), .http(500...599, _), .http(_, "rateLimitExceeded"),
             .http(_, "userRateLimitExceeded"), .http(_, "RATE_LIMIT_EXCEEDED"):
            nextStep = "Wait a few minutes and retry."
        case .http(_, "invalid_client"), .http(_, "unauthorized_client"):
            nextStep = "Check the saved Desktop OAuth client and its Google Cloud project."
        case .http(403, _):
            nextStep = "Check Gmail API access for the Google Cloud project and mailbox."
        default:
            nextStep = "Retry and check the status if the failure persists."
        }
        return failure(error.localizedDescription, nextStep: nextStep)
    }
}
