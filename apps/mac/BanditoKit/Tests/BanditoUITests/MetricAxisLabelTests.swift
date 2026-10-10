import Testing

@testable import BanditoUI

struct MetricAxisLabelTests {
    @Test func dropsOnlyAZeroFraction() {
        #expect(MetricDetailView.axisLabel("8,0 ГБ") == "8 ГБ")
        #expect(MetricDetailView.axisLabel("16.0 GB") == "16 GB")
        #expect(MetricDetailView.axisLabel("4,7 ГБ") == "4,7 ГБ")
        #expect(MetricDetailView.axisLabel("0,05 ГБ") == "0,05 ГБ")
        #expect(MetricDetailView.axisLabel("50 %") == "50 %")
    }

    @Test func memoryAxisUsesRoundSteps() {
        let cases: [[Double]] = [[16, 4, 16], [36, 10, 40], [18, 5, 20], [8, 2, 8]]
        for c in cases {
            let axis = MetricDetailView.memoryAxis(topGiB: c[0])
            let got = [axis.step, axis.top]
            #expect(got == [c[1], c[2]])
        }
    }
}
