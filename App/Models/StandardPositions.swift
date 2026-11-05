import Foundation

/// Standard 10-10 electrode positions, keyed by label (brief 003 "Engineering decisions":
/// a committed table of a published standard, never inference).
///
/// Source: the 10-10 grid of the five-percent system, Oostenveld R, Praamstra P (2001),
/// "The five percent electrode system for high-resolution EEG and ERP measurements",
/// Clin Neurophysiol 112(4):713–719, doi:10.1016/S1388-2457(00)00527-7, as distributed in
/// FieldTrip's `standard_1005.elc` and MNE-Python's `standard_1005` montage (MNI head,
/// Colin27). Only the regular 10 % grid is copied (86 sites, Fp…I rows); the 5 % sites,
/// fiducials and mastoid/ear points are not. Values are millimetres, rounded to 0.1 mm:
/// x to the subject's right, y anterior (nose), z up. Old 10-20 names T3/T4/T5/T6 are not
/// rows here: they resolve to T7/T8/P7/P8 under a declared 10-20 montage only, so one site
/// never has two points (decision lead default 4).
///
/// Regenerate (dev only; MNE never ships): `uv run python -c "import mne; ..."` over
/// `make_standard_montage('standard_1005').get_positions()['ch_pos']`, labels matching
/// `(Fp|AF|F|FT|FC|T|TP|C|CP|P|PO|O|I)(z|\d+)`, minus T3/T4/T5/T6.
enum StandardPositions {
    struct Site: Equatable, Sendable {
        /// The canonical 10-10 spelling ("FCz", "Fp1").
        let label: String
        /// Millimetres in the source's head frame (see the type comment).
        let x: Double, y: Double, z: Double
        var position: SIMD3<Double> { SIMD3(x, y, z) }
    }

    static let tenTen: [Site] = rows.map { Site(label: $0.0, x: $0.1, y: $0.2, z: $0.3) }

    /// The 10-20 sites (Jasper 1958) in 10-10 nomenclature (ACNS 2006): the 19 recording
    /// sites plus Fpz and Oz, which the 10-20 measurement defines. A1/A2 are not scalp sites
    /// in the source table and are left out.
    static let tenTwentyLabels: Set<String> = [
        "Fp1", "Fpz", "Fp2", "F7", "F3", "Fz", "F4", "F8", "T7", "C3", "Cz", "C4", "T8",
        "P7", "P3", "Pz", "P4", "P8", "O1", "Oz", "O2",
    ]

    /// Old 10-20 names → their 10-10 site; honoured under a 10-20 declaration only.
    static let tenTwentyAliases: [String: String] = ["T3": "T7", "T4": "T8", "T5": "P7", "T6": "P8"]

    static let byLabel: [String: Site] = Dictionary(uniqueKeysWithValues: tenTen.map { ($0.label, $0) })
    /// Lower-cased key → canonical label, for the case-insensitive lookup (lead default 1).
    static let canonical: [String: String] = Dictionary(uniqueKeysWithValues: tenTen.map { ($0.label.lowercased(), $0.label) })

    private static let rows: [(String, Double, Double, Double)] = [
        ("Fp1", -29.4, 83.9, -7.0),
        ("Fpz", 0.1, 88.2, -1.7),
        ("Fp2", 29.9, 84.9, -7.1),
        ("AF9", -49.0, 64.1, -47.7),
        ("AF7", -54.8, 68.6, -10.6),
        ("AF5", -45.4, 72.9, 6.0),
        ("AF3", -33.7, 76.8, 21.2),
        ("AF1", -18.5, 79.9, 32.8),
        ("AFz", 0.2, 80.8, 35.4),
        ("AF2", 19.8, 80.3, 32.8),
        ("AF4", 35.7, 77.7, 22.0),
        ("AF6", 46.6, 73.8, 6.0),
        ("AF8", 55.7, 69.7, -10.8),
        ("AF10", 50.4, 63.9, -48.0),
        ("F9", -70.1, 41.7, -50.0),
        ("F7", -70.3, 42.5, -11.4),
        ("F5", -64.5, 48.0, 16.9),
        ("F3", -50.2, 53.1, 42.2),
        ("F1", -27.5, 56.9, 60.3),
        ("Fz", 0.3, 58.5, 66.5),
        ("F2", 29.5, 57.6, 59.5),
        ("F4", 51.8, 54.3, 40.8),
        ("F6", 67.9, 49.8, 16.4),
        ("F8", 73.0, 44.4, -12.0),
        ("F10", 72.1, 42.1, -50.5),
        ("FT9", -84.1, 14.6, -50.4),
        ("FT7", -80.8, 14.1, -11.1),
        ("FC5", -77.2, 18.6, 24.5),
        ("FC3", -60.2, 22.7, 55.5),
        ("FC1", -34.1, 26.0, 80.0),
        ("FCz", 0.4, 27.4, 88.7),
        ("FC2", 34.8, 26.4, 78.8),
        ("FC4", 62.3, 23.7, 55.6),
        ("FC6", 79.5, 19.9, 24.4),
        ("FT8", 81.8, 15.4, -11.3),
        ("FT10", 84.1, 14.4, -50.5),
        ("T9", -85.9, -15.8, -48.3),
        ("T7", -84.2, -16.0, -9.3),
        ("C5", -80.3, -13.8, 29.2),
        ("C3", -65.4, -11.6, 64.4),
        ("C1", -36.2, -10.0, 89.8),
        ("Cz", 0.4, -9.2, 100.2),
        ("C2", 37.7, -9.6, 88.4),
        ("C4", 67.1, -10.9, 63.6),
        ("C6", 83.5, -12.8, 29.2),
        ("T8", 85.1, -15.0, -9.5),
        ("T10", 85.6, -16.4, -48.3),
        ("TP9", -85.6, -46.5, -45.7),
        ("TP7", -84.8, -46.0, -7.1),
        ("CP5", -79.6, -46.6, 30.9),
        ("CP3", -63.6, -47.0, 65.6),
        ("CP1", -35.5, -47.3, 91.3),
        ("CPz", 0.4, -47.3, 99.4),
        ("CP2", 38.4, -47.1, 90.7),
        ("CP4", 66.6, -46.6, 65.6),
        ("CP6", 83.3, -46.1, 31.2),
        ("TP8", 85.5, -45.5, -7.1),
        ("TP10", 86.2, -47.0, -45.9),
        ("P9", -73.0, -73.8, -41.0),
        ("P7", -72.4, -73.5, -2.5),
        ("P5", -67.3, -76.3, 28.4),
        ("P3", -53.0, -78.8, 55.9),
        ("P1", -28.6, -80.5, 75.4),
        ("Pz", 0.3, -81.1, 82.6),
        ("P2", 31.9, -80.5, 76.7),
        ("P4", 55.7, -78.6, 56.6),
        ("P6", 67.9, -75.9, 28.1),
        ("P8", 73.1, -73.1, -2.5),
        ("P10", 73.9, -74.4, -41.2),
        ("PO9", -54.9, -98.0, -35.5),
        ("PO7", -54.8, -97.5, 2.8),
        ("PO5", -48.4, -99.3, 21.6),
        ("PO3", -36.5, -100.9, 37.2),
        ("PO1", -19.0, -101.8, 46.5),
        ("POz", 0.2, -102.2, 50.6),
        ("PO2", 19.9, -101.8, 46.4),
        ("PO4", 36.8, -100.8, 36.4),
        ("PO6", 49.8, -99.4, 21.7),
        ("PO8", 55.7, -97.6, 2.7),
        ("PO10", 55.0, -98.1, -35.5),
        ("O1", -29.4, -112.4, 8.8),
        ("Oz", 0.1, -114.9, 14.7),
        ("O2", 29.8, -112.2, 8.8),
        ("I1", -29.8, -114.6, -29.2),
        ("Iz", 0.0, -118.6, -23.1),
        ("I2", 29.7, -114.3, -29.3),
    ]
}
