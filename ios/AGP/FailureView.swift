import UIKit

/// What the app shows when the dashboard is not answering — which, for a front
/// end to somebody's own server, is the normal failure and not an exceptional
/// one: the machine is off, the tunnel is down, the address is wrong. All three
/// are fixed from here.
final class FailureView: UIStackView {

    private let headline = UILabel()
    private let detail = UILabel()
    private let onRetry: () -> Void
    private let onSettings: () -> Void

    init(onRetry: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.onRetry = onRetry
        self.onSettings = onSettings
        super.init(frame: .zero)

        axis = .vertical
        alignment = .fill
        spacing = 12

        headline.text = "連不上主控台"
        headline.font = .systemFont(ofSize: 22, weight: .semibold)
        headline.textColor = .white
        headline.textAlignment = .center
        headline.numberOfLines = 0

        detail.font = .systemFont(ofSize: 15)
        detail.textColor = UIColor.white.withAlphaComponent(0.62)
        detail.textAlignment = .center
        detail.numberOfLines = 0

        addArrangedSubview(headline)
        addArrangedSubview(detail)
        setCustomSpacing(24, after: detail)
        addArrangedSubview(button("重新連線", filled: true, action: #selector(retry)))
        addArrangedSubview(button("更改伺服器位址", filled: false, action: #selector(settings)))
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(_ error: Error, address: URL) {
        detail.text = address.absoluteString + "\n" + error.localizedDescription
    }

    private func button(_ title: String, filled: Bool, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.setTitleColor(filled ? .white : UIColor.white.withAlphaComponent(0.72), for: .normal)
        button.backgroundColor = filled ? Theme.accent : UIColor.white.withAlphaComponent(0.08)
        button.layer.cornerRadius = 10
        button.heightAnchor.constraint(equalToConstant: 46).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func retry() { onRetry() }
    @objc private func settings() { onSettings() }
}
