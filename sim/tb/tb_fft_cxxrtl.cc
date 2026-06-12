// ===========================================================================
//  tb_fft_cxxrtl.cc  --  cycle-accurate RTL test of fft_mag against the golden
// ---------------------------------------------------------------------------
//  Compiles the ACTUAL Verilog (via yosys' CXXRTL backend) into C++ and drives
//  it like real hardware: reset, pulse start, stream N samples, collect the
//  magnitude spectrum, and compare every bin BIT-FOR-BIT with the vectors that
//  tools/spectra_gen.py produced. If this passes, the RTL and the NumPy-checked
//  fixed-point model are provably the same machine.
// ===========================================================================
#include "fft_mag.cc"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include <fstream>

using namespace cxxrtl_design;

static const int N    = 256;
static const int HALF = 128;
static const int PEAK_EXPECT = 19;

// read a $readmemh file (skips // comments), returns 16-bit words
static std::vector<int> read_mem(const std::string& path) {
    std::vector<int> v; std::ifstream f(path);
    if (!f) { fprintf(stderr, "cannot open %s\n", path.c_str()); exit(2); }
    std::string tok;
    while (f >> tok) {
        if (tok.size() >= 2 && tok[0] == '/' && tok[1] == '/') { std::getline(f, tok); continue; }
        v.push_back((int)strtol(tok.c_str(), nullptr, 16));
    }
    return v;
}

int main(int argc, char** argv) {
    std::string vroot = (argc > 1) ? argv[1] : "sim/vectors";
    auto input    = read_mem(vroot + "/tb_input_256.mem");
    auto expected = read_mem(vroot + "/tb_expected_mag_256.mem");

    p_fft__mag top;
    auto posedge = [&]() {
        top.p_clk.set<bool>(false); top.step();
        top.p_clk.set<bool>(true);  top.step();
    };

    // ---- reset ----
    top.p_rst.set<bool>(true);
    top.p_in__valid.set<bool>(false);
    top.p_start.set<bool>(false);
    for (int i = 0; i < 4; i++) posedge();
    top.p_rst.set<bool>(false);
    posedge();

    // ---- pulse start ----
    top.p_start.set<bool>(true);  posedge();
    top.p_start.set<bool>(false);

    // ---- stream N real samples (im = 0) ----
    for (int k = 0; k < N; k++) {
        top.p_in__valid.set<bool>(true);
        top.p_in__re.set<uint32_t>((uint32_t)(input[k] & 0xFFFF));
        top.p_in__im.set<uint32_t>(0);
        posedge();
    }
    top.p_in__valid.set<bool>(false);

    // ---- run compute + output, collect magnitude bins ----
    std::vector<int> mag(N, -1);
    int collected = 0, peak_bin = -1, peak_val = -1;
    for (int c = 0; c < 20000 && collected < N; c++) {
        posedge();
        if (top.p_mag__valid.get<bool>()) {
            int idx = (int)top.p_mag__idx.get<uint32_t>();
            int val = (int)top.p_mag.get<uint32_t>();
            if (idx >= 0 && idx < N) { mag[idx] = val; collected++; }
            if (val > peak_val && idx < HALF) { peak_val = val; peak_bin = idx; }
        }
    }

    // ---- compare against golden (bins 0..HALF-1) ----
    int mism = 0, first_bad = -1;
    for (int k = 0; k < HALF; k++) {
        if (mag[k] != expected[k]) { mism++; if (first_bad < 0) first_bad = k; }
    }

    printf("collected %d bins; peak bin = %d (expect %d)\n", collected, peak_bin, PEAK_EXPECT);
    printf("bit-exact mismatches vs golden (bins 0..%d): %d\n", HALF - 1, mism);
    if (mism && first_bad >= 0)
        printf("  first mismatch bin %d : rtl=%d golden=%d\n",
               first_bad, mag[first_bad], expected[first_bad]);

    bool ok = (peak_bin == PEAK_EXPECT) && (mism == 0) && (collected == N);
    printf("RESULT: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
