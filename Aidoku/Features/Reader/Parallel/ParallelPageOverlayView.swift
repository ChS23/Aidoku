//
//  ParallelPageOverlayView.swift
//  Aidoku
//
//  Full-screen overlay that shows the linked (translated) page while the
//  reader holds a finger on the page. The spot under the finger is aligned
//  with the matching spot of the linked page; moving the finger scrolls it.
//

import UIKit

final class ParallelPageOverlayView: UIView {
    private let contentView = UIView()
    private var imageViews: [UIImageView] = []
    private let spinner = UIActivityIndicatorView(style: .large)
    private let badge = UILabel()
    private let badgeContainer = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))

    /// y of the finger (in overlay coordinates) when the gesture started
    private var anchorY: CGFloat = 0
    /// finger movement since the gesture started
    private var translation: CGFloat = 0
    /// target page index and position inside it
    private var targetImageIndex = 0
    private var targetFraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        alpha = 0
        clipsToBounds = true

        addSubview(contentView)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        addSubview(spinner)

        badgeContainer.layer.cornerRadius = 12
        badgeContainer.layer.cornerCurve = .continuous
        badgeContainer.clipsToBounds = true
        badge.font = .systemFont(ofSize: 14, weight: .semibold)
        badge.textColor = .white
        badge.numberOfLines = 2
        badge.textAlignment = .center
        badgeContainer.contentView.addSubview(badge)
        addSubview(badgeContainer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public

    func begin(at fingerY: CGFloat) {
        anchorY = fingerY
        translation = 0
        clear()
        setBadge(nil)
        spinner.startAnimating()
        UIView.animate(withDuration: 0.12) { self.alpha = 1 }
        setNeedsLayout()
    }

    func moveFinger(to fingerY: CGFloat) {
        translation = fingerY - anchorY
        layoutContent()
    }

    func show(images: [UIImage], targetImageIndex: Int, fraction: CGFloat, label: String) {
        spinner.stopAnimating()
        clear()
        for image in images {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleToFill
            contentView.addSubview(imageView)
            imageViews.append(imageView)
        }
        self.targetImageIndex = targetImageIndex
        self.targetFraction = fraction
        setBadge(label)
        layoutContent()
    }

    func show(error message: String) {
        spinner.stopAnimating()
        clear()
        setBadge(message)
    }

    func end() {
        UIView.animate(withDuration: 0.12, animations: {
            self.alpha = 0
        }, completion: { _ in
            self.spinner.stopAnimating()
            self.clear()
        })
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        layoutBadge()
        layoutContent()
    }

    private func clear() {
        imageViews.forEach { $0.removeFromSuperview() }
        imageViews = []
    }

    private func setBadge(_ text: String?) {
        badge.text = text
        badgeContainer.isHidden = text == nil
        layoutBadge()
    }

    private func layoutBadge() {
        let maxWidth = bounds.width - 32
        let size = badge.sizeThatFits(CGSize(width: maxWidth - 24, height: .greatestFiniteMagnitude))
        let width = min(size.width + 24, maxWidth)
        let height = size.height + 12
        badgeContainer.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: safeAreaInsets.top + 12,
            width: width,
            height: height
        )
        badge.frame = badgeContainer.bounds.insetBy(dx: 12, dy: 6)
    }

    private func layoutContent() {
        guard !imageViews.isEmpty, bounds.width > 0 else { return }
        let width = bounds.width
        var y: CGFloat = 0
        var targetY: CGFloat = 0
        for (index, imageView) in imageViews.enumerated() {
            let size = imageView.image?.size ?? .zero
            let height = size.width > 0 ? width * size.height / size.width : 0
            imageView.frame = CGRect(x: 0, y: y, width: width, height: height)
            if index == targetImageIndex {
                targetY = y + height * targetFraction
            }
            y += height
        }
        // keep the matching spot under the finger, then follow finger movement
        contentView.frame = CGRect(x: 0, y: anchorY - targetY + translation, width: width, height: y)
    }
}
