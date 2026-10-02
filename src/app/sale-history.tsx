import {useEffect,useState} from 'react';
import {tradeCall} from '../lib/supabase';
import PagedList from './paged-list';
import {openConversation} from './inbox';
export default function SaleHistory({member,records}:{member:any,records:any[]}){
 const [data,setData]=useState<any>(null),[error,setError]=useState(''),[tab,setTab]=useState('purchases');
 async function refresh(){try{setData(await tradeCall('read'));setError('')}catch(e:any){setError(e.message)}}
 useEffect(()=>{refresh()},[member.id]);
 if(error)return <div className="notice">{error}<button onClick={refresh}>Retry</button></div>;if(!data)return <p>Loading history…</p>;
 const purchases=data.deals.filter((d:any)=>d.buyer===member.id&&d.stage==='complete'),sales=data.deals.filter((d:any)=>d.seller===member.id&&d.stage==='complete'),midman=data.deals.filter((d:any)=>d.midman===member.id&&d.stage==='complete');
 const tabs=[['purchases','Purchases',purchases.length],...((member.admin||['seller','midman'].includes(member.role))?[['sales','Sales',sales.length+data.outsideSales.length]]:[]),...(member.role==='midman'?[['midman','Midman',midman.length]]:[])];
 const entries=tab==='sales'?[...sales,...data.outsideSales.map((x:any)=>({...x,outside:true}))]:tab==='midman'?midman:purchases;
 const name=(id:string)=>records.find(r=>r.kind==='profile'&&r.owner===id)?.name||'Member';
 return <section><h2>Completed transaction history</h2><p className="form-help">Historical records of completed sales. Account passwords and recovery details are not stored here.</p><div className="tabs">{tabs.map(([id,label,count])=><button key={id} className={tab===id?'selected':''} onClick={()=>setTab(String(id))}>{label} ({count})</button>)}</div>{!entries.length&&<div className="empty"><h3>No completed records yet</h3><p>Completed transactions will appear here.</p></div>}<PagedList items={entries.map((d:any)=>{const listing=records.find(r=>r.id===d.listing),chat=data.interests.find((c:any)=>c.listing===d.listing&&c.buyer===d.buyer);return <article className="trust-card history-card" key={d.id||d.listing}>{listing?.image&&<img src={listing.image} alt={listing.title}/>}<div><span className="status-pill">{d.outside?'Sold outside · Seller recorded':'Completed · Midman confirmed'}</span><h3>{listing?.title||'Account listing'}</h3><p>{d.outside?'Buyer/reference: '+d.buyer_name:'Buyer: '+name(d.buyer)+' · Seller: '+name(d.seller)}</p><small>Transaction reference: {d.id||d.listing}</small><div className="history-actions"><a className="secondary" href={'/account/'+d.listing}>View account record</a>{chat&&<button className="quiet" onClick={()=>openConversation(chat.id)}>View historical chat</button>}</div></div></article>})}/></section>
}
