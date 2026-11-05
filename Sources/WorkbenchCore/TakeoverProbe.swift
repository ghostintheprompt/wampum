import Foundation

/// Subdomain-takeover classifier. Given what recon observed about a dangling-CNAME host — its
/// CNAME target, whether that target still resolves, and optionally the HTTP body served — it
/// returns a confidence-tiered lead. The core discriminator is RECLAIMABILITY: can an attacker
/// register the exact CNAME target and serve content from it?
///   - Reclaimable services (GitHub Pages, S3, Heroku, Netlify, Azure, Cloudflare/GitLab Pages,
///     Fastly custom, Shopify, etc.) let you claim a chosen name -> a dangling record is a real
///     takeover, strongest when the service serves its "unclaimed" fingerprint.
///   - Non-reclaimable targets (AWS ELB, DigitalOcean App, CloudFront) carry a provider-assigned
///     RANDOM component you cannot choose -> a dangling record is DNS hygiene, not a takeover.
///
/// Pure/deterministic (no DNS or HTTP here — the caller supplies the observations). A crossing is a
/// LEAD, promoted only through captured evidence + operator review + FindingVerification.
public enum TakeoverProbe {
    public enum Confidence: String, Codable, Sendable { case strong, moderate, weak, none }

    public struct Verdict: Codable, Equatable, Sendable {
        public let host: String
        public let cnameTarget: String
        public let service: String
        public let reclaimable: Bool
        public let confidence: Confidence
        public let detail: String
    }

    /// (CNAME-target suffix, service name, reclaimable, optional unclaimed-body fingerprint).
    private static let fingerprints: [(suffix: String, service: String, reclaimable: Bool, unclaimed: String?)] = [
        (".github.io", "GitHub Pages", true, "there isn't a github pages site here"),
        (".s3.amazonaws.com", "AWS S3", true, "nosuchbucket"),
        (".s3-website", "AWS S3 website", true, "nosuchbucket"),
        (".herokuapp.com", "Heroku", true, "no such app"),
        (".herokudns.com", "Heroku", true, "no such app"),
        (".netlify.app", "Netlify", true, "not found"),
        (".netlify.com", "Netlify", true, "not found"),
        (".pages.dev", "Cloudflare Pages", true, nil),
        (".gitlab.io", "GitLab Pages", true, nil),
        (".azurewebsites.net", "Azure App Service", true, nil),
        (".cloudapp.net", "Azure", true, nil),
        (".trafficmanager.net", "Azure Traffic Manager", true, nil),
        (".fastly.net", "Fastly", true, "fastly error: unknown domain"),
        (".domains.chromatic.com", "Chromatic", true, nil),
        (".myshopify.com", "Shopify", true, "sorry, this shop is currently unavailable"),
        (".ghost.io", "Ghost", true, nil),
        (".readthedocs.io", "Read the Docs", true, nil),
        (".wpengine.com", "WP Engine", true, nil),
        // Non-reclaimable: provider-random component in the name.
        (".elb.amazonaws.com", "AWS ELB", false, nil),
        (".ondigitalocean.app", "DigitalOcean App", false, nil),
        (".cloudfront.net", "AWS CloudFront", false, nil),
        (".map.fastly.net", "Fastly (mapped)", false, nil),
    ]

    public static func classify(host: String, cnameTarget: String, targetResolves: Bool, body: String = "") -> Verdict {
        let target = cnameTarget.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let b = body.lowercased()
        let match = fingerprints.first { target.hasSuffix($0.suffix) || target.contains($0.suffix) }
        let service = match?.service ?? "unknown"
        let reclaimable = match?.reclaimable ?? false

        // Target still resolves -> the record is live/claimed, not a takeover.
        if targetResolves {
            return Verdict(host: host, cnameTarget: cnameTarget, service: service, reclaimable: reclaimable,
                           confidence: .none, detail: "CNAME target still resolves — claimed/live, no takeover.")
        }
        // Dangling. Strength depends on reclaimability + an unclaimed fingerprint.
        if !reclaimable {
            return Verdict(host: host, cnameTarget: cnameTarget, service: service, reclaimable: false,
                           confidence: .weak, detail: "Dangling CNAME to \(service), but the target name carries a provider-random component you cannot reclaim — DNS hygiene, not a takeover.")
        }
        if let fp = match?.unclaimed, !b.isEmpty, b.contains(fp) {
            return Verdict(host: host, cnameTarget: cnameTarget, service: service, reclaimable: true,
                           confidence: .strong, detail: "Dangling CNAME to \(service) serving its unclaimed fingerprint — register \(cnameTarget) to claim \(host). Capture the PoC to promote.")
        }
        return Verdict(host: host, cnameTarget: cnameTarget, service: service, reclaimable: true,
                       confidence: .moderate, detail: "Dangling CNAME to reclaimable \(service) (target does not resolve) — attempt to register \(cnameTarget) and confirm control before reporting.")
    }
}
