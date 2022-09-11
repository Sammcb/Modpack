import Foundation
import Logging

struct ModpackLogHandler: LogHandler {
	enum Color: String {
		case gray = "7"
		case blue = "33"
		case green = "34"
		case yellow = "11"
		case red = "9"
		case purple = "13"
	}
	
	enum Mode: String {
		case none = ""
		case reset = "0"
		case bold = "1"
	}
	
	let label: String
	var logLevel: Logger.Level = .info
	var metadata: Logger.Metadata = [:]
	
	subscript(metadataKey key: String) -> Logger.Metadata.Value? {
		get {
			metadata[key]
		}
		set {
			metadata[key] = newValue
		}
	}
	
	init(label: String) {
		self.label = label
	}
	
	private func mode(for level: Logger.Level) -> Mode {
		switch level {
		case .trace, .debug, .notice: return .none
		case .info, .warning, .error, .critical: return .bold
		}
	}
	
	private func style(for level: Logger.Level, _ mode: Mode) -> String {
		let escape = "\u{001B}[38;5;"
		let modeSequence = mode == .none ? "" : "\u{001B}[\(mode.rawValue)m"
		switch level {
		case .trace: return "\(escape)\(Color.gray.rawValue)m\(modeSequence)"
		case .debug: return "\(escape)\(Color.blue.rawValue)m\(modeSequence)"
		case .info: return "\(escape)\(Color.green.rawValue)m\(modeSequence)"
		case .notice: return "\(escape)\(Color.yellow.rawValue)m\(modeSequence)"
		case .warning: return "\(escape)\(Color.yellow.rawValue)m\(modeSequence)"
		case .error: return "\(escape)\(Color.red.rawValue)m\(modeSequence)"
		case .critical: return "\(escape)\(Color.purple.rawValue)m\(modeSequence)"
		}
	}
	
	func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
		let mode = mode(for: level)
		let style = style(for: level, mode)
		print("\(style)\(message)\u{001B}[m")
	}
}

var logger = Logger(label: "com.sammcb.modpack", factory: ModpackLogHandler.init)
