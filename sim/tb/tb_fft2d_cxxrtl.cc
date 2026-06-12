// tb_fft2d_cxxrtl.cc -- 2D FFT RTL test: grating image -> bright-dot spectrum.
#include "fft2d.cc"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include <fstream>
using namespace cxxrtl_design;
static const int M = 32, MM = M*M;
static std::vector<int> rd(const std::string&p){std::vector<int> v;std::ifstream f(p);std::string t;
  if(!f){fprintf(stderr,"open %s\n",p.c_str());exit(2);} while(f>>t){if(t.size()>=2&&t[0]=='/'&&t[1]=='/'){std::getline(f,t);continue;} v.push_back((int)strtol(t.c_str(),0,16));} return v;}
int main(int argc,char**argv){
  std::string vr=(argc>1)?argv[1]:"sim/vectors";
  auto img=rd(vr+"/tb_img_input_32x32.mem");
  auto gold=rd(vr+"/tb_img_expected_mag_32x32.mem");
  p_fft2d top;
  auto pe=[&](){ top.p_clk.set<bool>(false);top.step(); top.p_clk.set<bool>(true);top.step(); };
  top.p_rst.set<bool>(true); top.p_img__valid.set<bool>(false); top.p_img__start.set<bool>(false);
  for(int i=0;i<4;i++) pe(); top.p_rst.set<bool>(false); pe();
  top.p_img__start.set<bool>(true); pe(); top.p_img__start.set<bool>(false);
  for(int k=0;k<MM;k++){ top.p_img__valid.set<bool>(true); top.p_img__pix.set<uint32_t>(img[k]&0xFFFF); pe(); }
  top.p_img__valid.set<bool>(false);
  std::vector<int> mag(MM,-1); int got=0;
  for(long c=0;c<2000000 && got<MM;c++){ pe();
    if(top.p_out__valid.get<bool>()){ int a=top.p_out__addr.get<uint32_t>(); int v=top.p_out__mag.get<uint32_t>();
      if(a>=0&&a<MM){ mag[a]=v; got++; } }
    if(top.p_frame__done.get<bool>() && got>=MM) break;
  }
  // peak (excluding DC)
  int pa=-1,pv=-1; for(int a=1;a<MM;a++) if(mag[a]>pv){pv=mag[a];pa=a;}
  int pr=pa/M, pc=pa%M;
  // golden peak
  int ga=-1,gv=-1; for(int a=1;a<MM;a++) if(gold[a]>gv){gv=gold[a];ga=a;}
  int gr=ga/M, gc=ga%M;
  int mism=0; for(int a=0;a<MM;a++) if(mag[a]!=gold[a]) mism++;
  printf("got=%d/%d  peak rtl=(%d,%d) val=%d  golden peak=(%d,%d) val=%d\n",
         got,MM,pr,pc,pv,gr,gc,gv);
  printf("bit-exact mismatches (1024 px): %d\n", mism);
  bool ok = (got==MM) && (pr==gr && pc==gc) && (mism==0);
  printf("RESULT: %s\n", ok?"PASS":"FAIL");
  return ok?0:1;
}
