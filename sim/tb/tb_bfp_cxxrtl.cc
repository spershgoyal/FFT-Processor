// tb_bfp_cxxrtl.cc -- fft_engine built with BFP=1 (block floating point).
// Runs every frame in sim/vectors/tb_bfp_frames.txt back to back through one
// engine instance and checks all 256 complex bins and the block exponent
// bit-exact against tools/bfp_study.py:fxp_fft_bfp().
#include "fft_engine_bfp.cc"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include <fstream>
using namespace cxxrtl_design;
static const int N = 256;
static int s16(int v){ v&=0xFFFF; return (v&0x8000)? v-0x10000 : v; }
int main(int argc,char**argv){
  std::string vr=(argc>1)?argv[1]:"sim/vectors";
  std::ifstream f(vr+"/tb_bfp_frames.txt");
  if(!f){fprintf(stderr,"open tb_bfp_frames.txt\n");return 2;}
  int nframes; f>>nframes;
  p_fft__engine top;
  auto pe=[&](){ top.p_clk.set<bool>(false);top.step(); top.p_clk.set<bool>(true);top.step(); };
  top.p_rst.set<bool>(true); top.p_in__valid.set<bool>(false); top.p_start.set<bool>(false);
  for(int i=0;i<4;i++) pe();
  top.p_rst.set<bool>(false); pe();
  int bad_frames=0, bad_bins=0, bad_exp=0, hist[9]={0};
  for(int fr=0;fr<nframes;fr++){
    std::vector<int> in(N),ere(N),eim(N); int eexp;
    for(auto&v:in) f>>v; f>>eexp; for(auto&v:ere) f>>v; for(auto&v:eim) f>>v;
    top.p_start.set<bool>(true); pe(); top.p_start.set<bool>(false);
    for(int k=0;k<N;k++){ top.p_in__valid.set<bool>(true); top.p_in__re.set<uint32_t>(in[k]&0xFFFF); top.p_in__im.set<uint32_t>(0); pe(); }
    top.p_in__valid.set<bool>(false);
    std::vector<int> gre(N,1<<20), gim(N,1<<20); int got=0, gexp=-1;
    for(int c=0;c<20000;c++){ pe();
      if(top.p_out__valid.get<bool>()){ int idx=top.p_out__idx.get<uint32_t>();
        gre[idx]=s16(top.p_out__re.get<uint32_t>()); gim[idx]=s16(top.p_out__im.get<uint32_t>());
        gexp=top.p_out__exp.get<uint32_t>(); got++; }
      if(top.p_done.get<bool>()) break; }
    int mism=0; for(int k=0;k<N;k++) if(gre[k]!=ere[k]||gim[k]!=eim[k]) mism++;
    if(got!=N||mism||gexp!=eexp){ bad_frames++; bad_bins+=mism; bad_exp+=(gexp!=eexp);
      if(bad_frames<=3) printf("  frame %d: got=%d mismatches=%d exp rtl=%d gold=%d\n",fr,got,mism,gexp,eexp); }
    if(eexp>=0&&eexp<=8) hist[eexp]++;
  }
  printf("frames=%d  bad frames=%d  bin mismatches=%d  exponent mismatches=%d\n",nframes,bad_frames,bad_bins,bad_exp);
  printf("frames by stages scaled (0..8):"); for(int i=0;i<=8;i++) printf(" %d",hist[i]); printf("\n");
  bool ok=(bad_frames==0); printf("RESULT: %s\n", ok?"PASS":"FAIL"); return ok?0:1;
}
