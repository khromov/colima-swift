import SwiftUI

enum ColimaStatus: String {
    case running
    case starting
    case stopping
    case stopped
    case unknown

    init(rawColimaStatus: String) {
        switch rawColimaStatus.lowercased() {
        case "running": self = .running
        case "stopped": self = .stopped
        default: self = .unknown
        }
    }

    var color: Color {
        switch self {
        case .running:  return .green
        case .starting, .stopping: return .yellow
        case .stopped:  return .red
        case .unknown:  return .gray
        }
    }

    var label: String {
        switch self {
        case .running:  return "Running"
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        case .stopped:  return "Stopped"
        case .unknown:  return "Unknown"
        }
    }
}

struct ColimaInstance: Codable {
    let name: String
    let status: String
    let arch: String
    let cpus: Int
    let memory: Int64
    let disk: Int64
    let runtime: String
}

struct VMProcessMetrics {
    let cpuPercent: Double
    let residentBytes: Int64
}

struct DockerStats {
    let total: Int
    let running: Int
}

struct DockerContainer {
    let id: String
    let name: String
    let image: String
    let status: String
}
