const https=require("https");
function request(url,secret){return new Promise((resolve,reject)=>https.get(url,{headers:{Authorization:"Bearer "+secret}},res=>{let b="";res.on("data",c=>b+=c);res.on("end",()=>{try{resolve({status:res.statusCode,data:JSON.parse(b)})}catch(e){reject(e)}})}).on("error",reject));}
module.exports=async(req,res)=>{
 res.setHeader("Cache-Control","no-store");
 if(req.method!=="GET") return res.status(405).json({error:"Method not allowed"});
 const secret=process.env.PAYSTACK_SECRET_KEY,ref=String(req.query?.reference||"");
 if(!secret)return res.status(503).json({error:"Payment verification is not configured."});
 if(!/^MAISON_[A-Z0-9_]+$/.test(ref))return res.status(400).json({error:"Invalid payment reference."});
 try{
  const result=await request("https://api.paystack.co/transaction/verify/"+encodeURIComponent(ref),secret);
  if(result.status!==200||!result.data.status)return res.status(502).json({error:"Could not verify payment with Paystack."});
  const tx=result.data.data;
  return res.status(200).json({status:tx.status,reference:tx.reference,currency:tx.currency,amount:tx.amount/100,paidAt:tx.paid_at,customerEmail:tx.customer?.email});
 }catch(e){return res.status(502).json({error:"Payment verification is temporarily unavailable."})}
};