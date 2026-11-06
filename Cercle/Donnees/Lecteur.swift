import UIKit
import Vision

/// Lecture du texte d'une image (capture d'écran, ticket) avec le framework Vision d'Apple, sur l'iPhone, sans Internet.
enum Lecteur {
    static func texte(_ image: UIImage) async -> String {
        guard let cg = image.cgImage else { return "" }
        return await withCheckedContinuation { suite in
            let requete = VNRecognizeTextRequest { r, _ in
                let lignes = (r.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
                suite.resume(returning: lignes.joined(separator: "\n"))
            }
            requete.recognitionLevel = .accurate
            requete.recognitionLanguages = ["fr-FR", "en-US"]
            requete.usesLanguageCorrection = true
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cg, orientation: .up).perform([requete]) }
                catch { suite.resume(returning: "") }
            }
        }
    }
}
