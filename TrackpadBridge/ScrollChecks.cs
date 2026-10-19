using System;
static class ScrollChecks {
 static void Main(string[] args) {
  var scroll=new NativeScroll();int x=0,y=0;
  for(int i=0;i<100;i++){var d=scroll.Convert(.25,-.25,i==0);x+=d[0];y+=d[1];}
  if(Math.Abs(x+30)>1 || Math.Abs(y+30)>1)throw new Exception("Fractional scroll lost");
  for(int i=0;i<100;i++){var d=scroll.Convert(-.25,.25,false);x+=d[0];y+=d[1];}
  if(Math.Abs(x)>1 || Math.Abs(y)>1)throw new Exception("Reverse scroll drift");
  scroll.Convert(.1,.1,false);
  var reset=scroll.Convert(100,-100,true);
  if(reset[0]!=-120 || reset[1]!=-120)throw new Exception("Sign/reset incorrect");
  if(args.Length==2 && args[0]=="--native") {
   scroll.Scroll(1,-1,true);scroll.Scroll(-1,1,false);
   System.IO.File.WriteAllText(args[1],"{\"fineScrollInjected\":true,\"reversed\":true,\"events\":"+scroll.Events+"}");
  }
  Console.WriteLine("PASS: sub-notch scroll, fractional carry, reversal, natural direction, begin reset; no input injected");
 }
}
