// tb_elec_cxxrtl.cc -- end-to-end electrical-diagnostics RTL test.
// Streams a 60Hz + 3/5/7-harmonic signal, checks peak bin, fundamental
// presence, high-THD flag, and THD value against the Python golden (~36.0%).
#include "spectrum_elec.cc"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <string>
#include <fstream>
using namespace cxxrtl_design;
static const int N = 256;
static std::vector<int> rd(const std::string&p){std::vector<int> v;std::ifstream f(p);std::string t;
  if(!f){fprintf(stderr,"open %s\n",p.c_str());exit(2);} while(f>>t){if(t.size()>=2&&t[0]=='/'&&t[1]=='/'){std::getline(f,t);continue;} v.push_back((int)strtol(t.c_str(),0,16));} return v;}

int main(int argc,char**argv){
  std::string vr=(argc>1)?argv[1]:"sim/vectors";
  auto in=rd(vr+"/tb_elec_input_256.mem");
  // read golden THD from the txt file
  double gold_thd=-1; int gold_fund_bin=-1, gold_peak=-1;
  { std::ifstream f(vr+"/tb_elec_expected_256.txt"); std::string k;
    while(f>>k){ if(k=="thd_percent"){f>>gold_thd;} else if(k=="fundamental_bin"){f>>gold_fund_bin;} else if(k=="peak_bin"){f>>gold_peak;} else {std::string rest; std::getline(f,rest);} } }

  p_spectrum__elec top;
  auto pe=[&](){ top.p_clk.set<bool>(false);top.step(); top.p_clk.set<bool>(true);top.step(); };
  top.p_rst.set<bool>(true); top.p_in__valid.set<bool>(false); top.p_start.set<bool>(false);
  for(int i=0;i<4;i++) pe();
  top.p_rst.set<bool>(false); pe();
  top.p_start.set<bool>(true); pe(); top.p_start.set<bool>(false);
  for(int k=0;k<N;k++){ top.p_in__valid.set<bool>(true); top.p_in__re.set<uint32_t>(in[k]&0xFFFF); pe(); }
  top.p_in__valid.set<bool>(false);

  int thd_pm=-1, peak=-1, fund=-1, fpres=-1, hthd=-1;
  for(int c=0;c<40000;c++){ pe();
    if(top.p_result__valid.get<bool>()){
      thd_pm=top.p_thd__pm.get<uint32_t>();
      peak=top.p_peak__bin.get<uint32_t>();
      fund=top.p_fund__mag.get<uint32_t>();
      fpres=top.p_fund__present.get<bool>();
      hthd=top.p_high__thd.get<bool>();
      break; } }

  double rtl_thd = thd_pm/10.0;
  printf("RTL: peak_bin=%d fund_mag=%d THD=%.1f%% (pm=%d) fund_present=%d high_thd=%d\n",
         peak, fund, rtl_thd, thd_pm, fpres, hthd);
  printf("GOLD: peak_bin=%d fund_bin=%d THD=%.1f%%\n", gold_peak, gold_fund_bin, gold_thd);
  bool ok = (peak==gold_peak) && fpres==1 && hthd==1
            && (thd_pm>=0) && (rtl_thd > gold_thd-3.0) && (rtl_thd < gold_thd+3.0);
  printf("RESULT: %s\n", ok?"PASS":"FAIL");
  return ok?0:1;
}
