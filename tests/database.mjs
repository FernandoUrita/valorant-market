import {PGlite} from '@electric-sql/pglite';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite();
await db.exec("create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz,raw_user_meta_data jsonb default '{}');create function auth.uid() returns uuid language sql as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;");
await db.exec("create schema storage;create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);create table storage.objects(id uuid default gen_random_uuid(),bucket_id text,name text);alter table storage.objects enable row level security;grant usage on schema storage to authenticated;grant select,insert on storage.objects to authenticated;");
await db.exec(fs.readFileSync('supabase/setup.sql','utf8'));
const ids={admin:'00000000-0000-4000-8000-000000000001',seller:'00000000-0000-4000-8000-000000000002',buyer:'00000000-0000-4000-8000-000000000003',stranger:'00000000-0000-4000-8000-000000000004',midman:'00000000-0000-4000-8000-000000000005'};
for(const [name,id] of Object.entries(ids)){await db.query('insert into auth.users(id,email,email_confirmed_at) values($1,$2,now())',[id,name==='admin'?'uritaf40@gmail.com':name+'@example.com'])}
async function as(name){await db.query("select set_config('request.jwt.claim.sub',$1,false)",[ids[name]||''])}
async function read(scope='market'){return (await db.query('select public.vm_read($1) as d',[scope])).rows[0].d}
async function write(action,payload){return (await db.query('select public.vm_write($1,$2::jsonb) as d',[action,JSON.stringify(payload)])).rows[0].d}
await as('seller');assert.equal((await read()).user.role,'buyer');assert.equal((await read()).user.credits,100);
await write('request-role',{role:'seller',details:'I have experience selling accounts.'});let rr=(await read('trust')).requests[0];await assert.rejects(()=>write('review-role',{id:rr.id,decision:'approved'}));
await as('admin');await read();await write('review-role',{id:rr.id,decision:'approved'});
await as('midman');await read();await write('request-role',{role:'midman',details:'I can coordinate transactions.'});rr=(await read('trust')).requests[0];await as('admin');await write('review-role',{id:rr.id,decision:'approved'});
await as('buyer');await read();await as('stranger');await read();await as('seller');
await write('save-record',{kind:'profile',data:{name:'Seller',bio:'Hello',email:'seller@example.com',facebook:'https://facebook.com/seller',whatsapp:'09171234567',role:'midman',credits:1000}});assert.equal((await read()).user.role,'seller');
const catalog=JSON.parse(fs.readFileSync('src/lib/catalog.json','utf8'));const inv=Object.fromEntries(Object.entries(catalog).map(([k,v])=>[k,[v[0].id]]));
const listing={title:'Test account',price:'3500',rank:'Gold',region:'APAC',level:'50',description:'Collection details',image:catalog.weapons[0].image,urgency:'rush',inventory:inv};
const lid=(await write('save-record',{kind:'listing',data:listing})).id;assert.deepEqual((await read()).records.find(r=>r.id===lid).inventory,inv);
await db.query('insert into vm.deals(listing,seller,buyer) values($1,$2,$3)',[lid,ids.seller,ids.buyer]);let deal=(await read('trust')).deals[0];
await as('stranger');await assert.rejects(()=>write('confirm-deal',{id:deal.id}));
await as('buyer');await write('confirm-deal',{id:deal.id});await as('seller');assert.equal((await read('trust')).members.find(m=>m.id===ids.seller).sales,1);assert.equal((await read()).records.find(r=>r.id===lid).sold,true);
for(let i=0;i<4;i++){
 await as('seller');const newlid=(await write('save-record',{kind:'listing',data:listing})).id;
 await as('buyer');await write('report',{listingId:newlid,reason:'Reported transaction issue',evidence:'Evidence details with links'});const rep=(await read('trust')).reports.find(r=>r.listing===newlid);
 await as('stranger');await assert.rejects(()=>write('review-report',{id:rep.id,decision:'confirmed'}));
 await as('admin');await write('review-report',{id:rep.id,decision:'confirmed'});await assert.rejects(()=>write('review-report',{id:rep.id,decision:'confirmed'}));
}
await as('seller');assert.equal((await read()).user.suspended,true);await assert.rejects(()=>write('request-role',{role:'midman',details:'Request while suspended'}));
await db.query("update vm.members set suspended_until=now()-interval '1 second' where id=$1",[ids.seller]);assert.equal((await read()).user.credits,25);assert.equal((await read()).user.suspended,undefined);
await as('buyer');await write('save-record',{kind:'inquiry',data:{listingId:lid,sellerId:ids.stranger,message:'Hello seller'}});const inquiries=(await read()).records.filter(r=>r.kind==='inquiry');assert.equal(inquiries[0].sellerId,ids.seller);
await as('stranger');assert.equal((await read()).records.filter(r=>r.kind==='inquiry').length,0);
async function chat(action,data={}){return (await db.query('select public.vm_chat($1,$2::jsonb) as d',[action,JSON.stringify(data)])).rows[0].d}
await db.exec(fs.readFileSync('supabase/002-interest-chat.sql','utf8')); // migration can be re-run
await db.exec(fs.readFileSync('supabase/003-transactions.sql','utf8'));
await as('seller');const chatListing=(await write('save-record',{kind:'listing',data:listing})).id;
await assert.rejects(()=>chat('interest',{listingId:chatListing}));
await as('buyer');await assert.rejects(()=>chat('interest',{listingId:lid}));
const first=await chat('interest',{listingId:chatListing,channel:'whatsapp'});assert.equal(first.created,true);
const again=await chat('interest',{listingId:chatListing,channel:'copy'});assert.equal(again.threadId,first.threadId);assert.equal(again.created,false);
assert.equal((await chat('messages',{threadId:first.threadId})).messages.length,1);
await as('seller');let inbox=await chat('inbox');assert.equal(inbox.threads[0].unread,1);assert.equal(inbox.threads[0].buyer,ids.buyer);assert.equal(inbox.threads[0].channel,'copy');
const shown=(await chat('messages',{threadId:first.threadId})).messages;
await chat('seen',{threadId:first.threadId,lastId:shown.at(-1).id});assert.equal((await chat('inbox')).threads[0].unread,0);
await chat('send',{threadId:first.threadId,body:'Yes, still available.'});
await as('buyer');assert.equal((await chat('inbox')).threads[0].unread,1);
await as('stranger');assert.equal((await chat('inbox')).threads.length,0);await assert.rejects(()=>chat('messages',{threadId:first.threadId}));await assert.rejects(()=>chat('send',{threadId:first.threadId,body:'Unauthorized'}));await assert.rejects(()=>chat('seen',{threadId:first.threadId,lastId:999999}));
await db.query("update vm.members set suspended_until=now()+interval '1 day' where id=$1",[ids.buyer]);await as('buyer');await assert.rejects(()=>chat('inbox'));await assert.rejects(()=>chat('send',{threadId:first.threadId,body:'Suspended'}));await db.query('update vm.members set suspended_until=null where id=$1',[ids.buyer]);
await as('');await db.exec('set role anon');await assert.rejects(()=>chat('inbox'));await db.exec('reset role');
await as('buyer');await db.exec('set role authenticated');assert.equal((await chat('inbox')).threads.length,1);await assert.rejects(()=>db.query('select * from vm.messages'));await db.exec('reset role');
async function trade(action,data={}){return (await db.query('select public.vm_trade($1,$2::jsonb) as d',[action,JSON.stringify(data)])).rows[0].d}
await as('admin');await trade('admin-role',{role:'seller'});assert.equal((await read()).user.role,'seller');
await as('buyer');await assert.rejects(()=>trade('admin-role',{role:'midman'}));await assert.rejects(()=>trade('apply',{listingId:chatListing}));
await as('midman');await trade('apply',{listingId:chatListing});await as('seller');await trade('start',{listingId:chatListing,buyer:ids.buyer,midman:ids.midman});
let staged=(await trade('read')).deals.find(d=>d.listing===chatListing);assert.equal(staged.stage,'awaiting_payment');await assert.rejects(()=>trade('seller-approve',{id:staged.id}));
await as('midman');await assert.rejects(()=>trade('complete',{id:staged.id}));await as('buyer');await assert.rejects(()=>write('confirm-deal',{id:staged.id}));
const proofPath=ids.buyer+'/'+staged.id+'/proof.png';await db.query('insert into storage.objects(bucket_id,name) values($1,$2)',['vm-payment-proofs',proofPath]);
await trade('proof',{id:staged.id,path:proofPath});await as('stranger');assert.equal((await trade('read')).deals.length,0);await assert.rejects(()=>trade('seller-approve',{id:staged.id}));
await as('seller');await trade('seller-approve',{id:staged.id});assert.equal((await read()).records.find(r=>r.id===chatListing).sold,false);
await as('midman');await trade('revision',{id:staged.id,note:'Please send the correct receipt.'});await assert.rejects(()=>trade('complete',{id:staged.id}));
await as('buyer');await trade('proof',{id:staged.id,path:proofPath});await as('seller');await trade('seller-approve',{id:staged.id});await as('midman');await trade('complete',{id:staged.id});await assert.rejects(()=>trade('complete',{id:staged.id}));
await as('seller');assert.equal((await read()).records.find(r=>r.id===chatListing).sold,true);
const outside=(await write('save-record',{kind:'listing',data:listing})).id;await trade('outside',{listingId:outside,buyerName:'Outside buyer reference'});assert.equal((await read()).records.find(r=>r.id===outside).sold,true);await assert.rejects(()=>trade('outside',{listingId:outside,buyerName:'Again'}));
await as('buyer');await assert.rejects(()=>chat('interest',{listingId:outside}));
await db.exec('set role authenticated');assert.equal((await db.query('select * from storage.objects')).rows.length,1);await db.exec('reset role');await as('stranger');await db.exec('set role authenticated');assert.equal((await db.query('select * from storage.objects')).rows.length,0);await assert.rejects(()=>db.query('insert into storage.objects(bucket_id,name) values($1,$2)',['vm-payment-proofs',proofPath]));await db.exec('reset role');
console.log('PASS: admin direct role, verified Midman applications, interested buyer assignment, ordered proof/review/final confirmation, correction cycle, outside sale and private proof policies.');
console.log('PASS: chat migration, unique interest, unread notifications, replies, sold/self rejection, participant privacy, suspension and RPC permissions.');
await as('');assert.equal((await read()).user,null);
await db.exec('set role anon');await assert.rejects(()=>db.query('select * from vm.members'));await assert.rejects(()=>write('request-role',{role:'seller',details:'Untrusted request'}));await read();await db.exec('reset role');
console.log('PASS: schema, inventory, roles, admin authorization, transaction confirmation, null-midman ownership, credits, report idempotency, suspension/recovery, private inquiries, anonymous access restrictions.');await db.close();
