import UIKit
import Vision

/// Lecture du texte d'une image (capture d'écran, ticket) avec le framework Vision d'Apple, sur l'iPhone, sans Internet.
enum Lecteur {
    static func texte(_ image: UIImage) async -> String {
        guard let cg = image.cgImage else { return "" }
        let sens = orientation(image.imageOrientation)   // une photo de ticket prise en portrait n'est pas « droite » dans le fichier
        return await withCheckedContinuation { suite in
            // Vision peut appeler la fin ET lever une erreur : on ne répond qu'une seule fois (sinon l'app plante)
            let une = UneFois(suite)
            let requete = VNRecognizeTextRequest { r, _ in
                let lignes = (r.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
                une.repondre(lignes.joined(separator: "\n"))
            }
            requete.recognitionLevel = .accurate
            requete.recognitionLanguages = ["fr-FR", "en-US"]
            requete.usesLanguageCorrection = true
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: cg, orientation: sens).perform([requete]) }
                catch { une.repondre("") }
            }
        }
    }

    private final class UneFois: @unchecked Sendable {
        private let verrou = NSLock()
        private var suite: CheckedContinuation<String, Never>?
        init(_ s: CheckedContinuation<String, Never>) { suite = s }
        func repondre(_ t: String) {
            verrou.lock(); let s = suite; suite = nil; verrou.unlock()
            s?.resume(returning: t)
        }
    }

    private static func orientation(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
