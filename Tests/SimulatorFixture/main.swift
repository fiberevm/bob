import UIKit

@main final class SimulatorFixture: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = FixtureController()
        window?.makeKeyAndVisible()
        return true
    }
}

private final class FixtureController: UIViewController {
    let textField = UITextField()
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .red
        textField.backgroundColor = .white
        textField.textColor = .black
        textField.placeholder = "Type here"
        textField.autocorrectionType = .no
        textField.addTarget(self, action: #selector(typed), for: .editingChanged)
        view.addSubview(textField)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged)))
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        textField.frame = CGRect(x: view.bounds.width * 0.1, y: view.bounds.height * 0.25, width: view.bounds.width * 0.8, height: 50)
    }
    @objc func tapped(_ recognizer: UITapGestureRecognizer) {
        if textField.frame.contains(recognizer.location(in: view)) { textField.becomeFirstResponder() }
        else { view.backgroundColor = .green }
    }
    @objc func dragged(_ recognizer: UIPanGestureRecognizer) { if recognizer.state == .ended { view.backgroundColor = .yellow } }
    @objc func typed() { view.backgroundColor = .blue }
}
