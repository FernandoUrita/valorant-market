import {createClient} from '@supabase/supabase-js';
export const supabase=createClient(import.meta.env.VITE_SUPABASE_URL||'https://msmvmrzfaltsgdpaluyw.supabase.co',import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY||'sb_publishable_hpXlazDIFAwTZLdUqwV7Hg_MOmQcfSe',{auth:{flowType:'pkce',detectSessionInUrl:true,persistSession:true,autoRefreshToken:true}});
export async function appFetch(path:string,options:RequestInit={}){
 const method=options.method||'GET';const isTrust=path==='/api/trust';let result;
 if(method==='GET')result=await supabase.rpc('vm_read',{p_scope:isTrust?'trust':'market'});
 else {const input=JSON.parse(String(options.body||'{}'));result=await supabase.rpc('vm_write',{p_action:method==='DELETE'?'delete-record':isTrust?input.action:'save-record',p_data:input});}
 const {data,error}=result;return {ok:!error&&(!data?.error),status:error?.code==='42501'?401:error?503:data?.error?400:200,json:async()=>error?{error:error.code==='PGRST202'?'Database setup is incomplete. Run the provided Supabase SQL setup file.':error.message}:data};
}
export async function chatCall(action:string,data:any={}){
 const {data:result,error}=await supabase.rpc('vm_chat',{p_action:action,p_data:data});
 if(error)throw Error(error.code==='PGRST202'?'Chat setup is incomplete. Run supabase/002-interest-chat.sql in Supabase SQL Editor.':error.message);
 return result;
}
export async function tradeCall(action:string,data:any={}){const {data:result,error}=await supabase.rpc('vm_trade',{p_action:action,p_data:data});if(error)throw Error(error.code==='PGRST202'?'Transaction setup is incomplete. Run supabase/003-transactions.sql.':error.message);return result;}
