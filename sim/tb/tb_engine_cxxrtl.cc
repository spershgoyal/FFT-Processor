// tb_engine_cxxrtl.cc -- drive fft_engine, check COMPLEX output bit-exact.
#include "fft_engine.cc"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include <fstream>
using namespace cxxrtl_design;
static const int N = 256;
static int s16(int v){ v&=0xFFFF; return (v&0x8000)? v-0x10000 : v; }
static std::vector<int> rd(const std::string&p){std::vector<int> v;std::ifstream f(p);std::string t;
  if(!f){fprintf(stderr,"open %s\n",p.c_str());exit(2);} while(f>>t){if(t.size()>=2&&t[0]=='/'&&t[1]=='/'){std::getline(f,t);continue;} v.push_back((int)strtol(t.c_str(),0,16));} return v;}
int main(int argc,char**argv){
  std::string vr=(argc>1)?argv[1]:"sim/vectors";
  auto in=rd(vr+"/tb_input_256.mem");
  auto ere=rd(vr+"/tb_expected_re_256.mem");
  auto eim=rd(vr+"/tb_expected_im_256.mem");
  p_fft__engine top;
  auto pe=[&](){ top.p_clk.set<bool>(false);top.step(); top.p_clk.set<bool>(true);top.step(); };
  top.p_rst.set<bool>(true); top.p_in__valid.set<bool>(false); top.p_start.set<bool>(false);
  for(int i=0;i<4;i++) pe();
  top.p_rst.set<bool>(false); pe();
  top.p_start.set<bool>(true); pe(); top.p_start.set<bool>(false);
  for(int k=0;k<N;k++){ top.p_in__valid.set<bool>(true); top.p_in__re.set<uint32_t>(in[k]&0xFFFF); top.p_in__im.set<uint32_t>(0); pe(); }
  top.p_in__valid.set<bool>(false);
  std::vector<int> gre(N,1<<20), gim(N,1<<20);
  int got=0;
  for(int c=0;c<20000&&got<N;c++){ pe();
    if(top.p_out__valid.get<bool>()){ int idx=top.p_out__idx.get<uint32_t>();
      if(idx>=0&&idx<N){ gre[idx]=s16(top.p_out__re.get<uint32_t>()); gim[idx]=s16(top.p_out__im.get<uint32_t>()); got++; } } }
  int mism=0,fb=-1;
  for(int k=0;k<N;k++){ if(gre[k]!=s16(ere[k])||gim[k]!=s16(eim[k])){ mism++; if(fb<0)fb=k; } }
  printf("got=%d  complex mismatches=%d\n",got,mism);
  for(int k=15;k<24;k++) printf("  bin%d rtl=(%d,%d) gold=(%d,%d)\n",k,gre[k],gim[k],s16(ere[k]),s16(eim[k]));
  if(fb>=0) printf("first mismatch bin %d rtl=(%d,%d) gold=(%d,%d)\n",fb,gre[fb],gim[fb],s16(ere[fb]),s16(eim[fb]));
  bool ok=(mism==0&&got==N); printf("RESULT: %s\n", ok?"PASS":"FAIL"); return ok?0:1;
}
