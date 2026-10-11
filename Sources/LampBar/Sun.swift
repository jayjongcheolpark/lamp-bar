import Foundation

/// Sunset time from the NOAA solar calculation (accurate to about a minute).
enum Sun {
    static func sunset(on day: Date, latitude: Double, longitude: Double) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // Use the local calendar day, solved at UTC noon of that date.
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        guard let noon = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12)) else { return nil }

        let julianDay = noon.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (julianDay - 2_451_545) / 36_525
        let rad = Double.pi / 180

        let meanLongitude = (280.46646 + t * (36_000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let meanAnomaly = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let center = sin(meanAnomaly * rad) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * meanAnomaly * rad) * (0.019993 - 0.000101 * t)
            + sin(3 * meanAnomaly * rad) * 0.000289
        let trueLongitude = meanLongitude + center
        let omega = 125.04 - 1934.136 * t
        let apparentLongitude = trueLongitude - 0.00569 - 0.00478 * sin(omega * rad)
        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = meanObliquity + 0.00256 * cos(omega * rad)
        let declination = asin(sin(obliquity * rad) * sin(apparentLongitude * rad))

        let y = pow(tan(obliquity * rad / 2), 2)
        let equationOfTime = 4 / rad * (y * sin(2 * meanLongitude * rad)
            - 2 * eccentricity * sin(meanAnomaly * rad)
            + 4 * eccentricity * y * sin(meanAnomaly * rad) * cos(2 * meanLongitude * rad)
            - 0.5 * y * y * sin(4 * meanLongitude * rad)
            - 1.25 * eccentricity * eccentricity * sin(2 * meanAnomaly * rad))

        // The sun's center 0.833 degrees below the horizon (refraction and the sun's radius).
        let cosHourAngle = cos(90.833 * rad) / (cos(latitude * rad) * cos(declination)) - tan(latitude * rad) * tan(declination)
        guard abs(cosHourAngle) <= 1 else { return nil } // polar day or night
        let hourAngle = acos(cosHourAngle) / rad

        let solarNoonMinutes = 720 - 4 * longitude - equationOfTime
        let sunsetMinutes = solarNoonMinutes + 4 * hourAngle
        let midnight = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))!
        return midnight.addingTimeInterval(sunsetMinutes * 60)
    }
}
