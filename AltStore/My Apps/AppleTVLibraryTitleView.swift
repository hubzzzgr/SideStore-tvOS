import UIKit

/// A stable navigation-title size, including before progress text is populated.
final class AppleTVLibraryTitleView: UIView {
    init(button: UIButton, statusLabel: UILabel) {
        super.init(frame: CGRect(x: 0, y: 0, width: 240, height: 44))
        for child in [button, statusLabel] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        let caret = UIImageView(image: UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)))
        caret.tintColor = .label
        caret.isUserInteractionEnabled = false
        caret.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(caret)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.heightAnchor.constraint(equalToConstant: 28),
            statusLabel.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 1),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            caret.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -10),
            caret.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { return nil }
    override var intrinsicContentSize: CGSize { CGSize(width: 240, height: 44) }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width > 0 ? min(240, size.width) : 240, height: 44)
    }
}
