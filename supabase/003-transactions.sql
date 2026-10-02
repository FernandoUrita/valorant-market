-- Run after setup.sql and 002-interest-chat.sql. Preserves existing records.
begin;
insert into vm.admin_emails values ('fernandourita0@gmail.com') on conflict do nothing;
alter table vm.deals add column if not exists stage text not null default 'legacy';
alter table vm.deals add column if not exists proof_path text;
alter table vm.deals add column if not exists review_note text;
create table if not exists vm.external_sales(listing uuid primary key references vm.records(id),seller uuid not null references auth.users(id),buyer_name text not null,created timestamptz default now());
create table if not exists vm.midman_applications(listing uuid not null references vm.records(id),member uuid not null references auth.users(id),created timestamptz default now(),primary key(listing,member));
alter table vm.external_sales enable row level security;
alter table vm.midman_applications enable row level security;
revoke all on vm.external_sales,vm.midman_applications from public,anon,authenticated;
create or replace function vm.is_sold(p_listing uuid) returns boolean language sql stable security definer set search_path='' as $$
select exists(select 1 from vm.external_sales e where e.listing=p_listing) or exists(select 1 from vm.deals d where d.listing=p_listing and d.seller_confirmed=1 and d.buyer_confirmed=1 and (d.midman is null or d.midman_confirmed=1));$$;
create or replace function vm.proof_access(p_name text,p_upload boolean default false) returns boolean language sql stable security definer set search_path='' as $$
select exists(select 1 from vm.deals d join vm.members m on m.id=auth.uid() where (m.suspended_until is null or m.suspended_until<=now()) and p_name like d.buyer::text||'/'||d.id::text||'/%' and case when p_upload then auth.uid()=d.buyer and d.stage in ('awaiting_payment','revision') else auth.uid() in(d.buyer,d.seller,d.midman) end);$$;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('vm-payment-proofs','vm-payment-proofs',false,5242880,array['image/png','image/jpeg','image/webp']) on conflict(id) do update set public=false,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists vm_proof_insert on storage.objects;
create policy vm_proof_insert on storage.objects for insert to authenticated with check(bucket_id='vm-payment-proofs' and vm.proof_access(name,true));
drop policy if exists vm_proof_select on storage.objects;
create policy vm_proof_select on storage.objects for select to authenticated using(bucket_id='vm-payment-proofs' and vm.proof_access(name,false));
revoke all on function vm.is_sold(uuid),vm.proof_access(text,boolean) from public,anon,authenticated;
-- Policy helper must be callable; private tables remain inaccessible.
grant usage on schema vm to authenticated;
grant execute on function vm.proof_access(text,boolean) to authenticated;
create or replace function public.vm_trade(p_action text,p_data jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare m vm.members;r vm.records;d vm.deals;b uuid;mid uuid;proof text;name text;note text;
begin
 m:=vm.ensure_member();if m.suspended_until>now() then raise exception 'Your account is temporarily suspended.' using errcode='42501';end if;
 if p_action='read' then
 return jsonb_build_object('deals',coalesce((select jsonb_agg(to_jsonb(dd) order by dd.created desc) from vm.deals dd where m.id in(dd.buyer,dd.seller,dd.midman)),'[]'::jsonb),'interests',coalesce((select jsonb_agg(to_jsonb(c)) from vm.conversations c where c.seller=m.id),'[]'::jsonb),'applications',coalesce((select jsonb_agg(to_jsonb(a)) from vm.midman_applications a join vm.records rr on rr.id=a.listing where a.member=m.id or rr.owner=m.id),'[]'::jsonb),'outsideSales',coalesce((select jsonb_agg(to_jsonb(e)) from vm.external_sales e where e.seller=m.id),'[]'::jsonb));
 elsif p_action='admin-role' then
 if not vm.is_admin() or p_data->>'role' not in('seller','midman') then raise exception 'Administrator permission required.' using errcode='42501';end if;
 update vm.members set role=p_data->>'role' where id=m.id;return jsonb_build_object('ok',true);
 elsif p_action in ('apply','start','outside') then
 select * into r from vm.records where id=(p_data->>'listingId')::uuid and kind='listing' for update;
 if r.id is null or vm.is_sold(r.id) then raise exception 'Listing is unavailable or sold.';end if;
 if exists(select 1 from vm.deals dd where dd.listing=r.id) then raise exception 'A transaction is already assigned to this listing.';end if;
 if p_action='apply' then
 if m.role<>'midman' or r.owner=m.id then raise exception 'Only verified Midmen can apply to another seller’s listing.' using errcode='42501';end if;
 insert into vm.midman_applications(listing,member) values(r.id,m.id) on conflict do nothing;
 else
 if r.owner<>m.id or (m.role not in('seller','midman') and not vm.is_admin()) then raise exception 'Only this seller can start a sale.' using errcode='42501';end if;
 if p_action='outside' then
 name:=trim(coalesce(p_data->>'buyerName',''));if length(name) not between 1 and 150 then raise exception 'Enter the outside buyer name or reference.';end if;
 insert into vm.external_sales(listing,seller,buyer_name) values(r.id,m.id,name);
 else
 b:=(p_data->>'buyer')::uuid;mid:=(p_data->>'midman')::uuid;
 if b is null or mid is null or b=mid or b=m.id or mid=m.id then raise exception 'Choose a distinct interested buyer and verified Midman.';end if;
 if not exists(select 1 from vm.conversations c where c.listing=r.id and c.buyer=b) or not exists(select 1 from vm.members mm where mm.id=b and (mm.suspended_until is null or mm.suspended_until<=now())) then raise exception 'Choose an active interested buyer.';end if;
 if not exists(select 1 from vm.midman_applications a join vm.members mm on mm.id=a.member where a.listing=r.id and a.member=mid and mm.role='midman' and (mm.suspended_until is null or mm.suspended_until<=now())) then raise exception 'Choose a verified Midman who applied to this listing.';end if;
 insert into vm.deals(listing,seller,buyer,midman,seller_confirmed,stage) values(r.id,m.id,b,mid,0,'awaiting_payment');
 end if;end if;
 else
 select * into d from vm.deals where id=(p_data->>'id')::uuid for update;
 if d.id is null or m.id not in(d.seller,d.buyer,d.midman) then raise exception 'Only assigned transaction participants have access.' using errcode='42501';end if;
 if p_action='proof' then
 if m.id<>d.buyer or d.stage not in('awaiting_payment','revision') then raise exception 'Only the assigned buyer can submit payment proof at this stage.';end if;
 proof:=p_data->>'path';if proof is null or proof not like d.buyer::text||'/'||d.id::text||'/%' or not vm.proof_access(proof,true) or not exists(select 1 from storage.objects o where o.bucket_id='vm-payment-proofs' and o.name=proof) then raise exception 'Upload a payment screenshot for this transaction first.';end if;
 update vm.deals set proof_path=proof,stage='seller_review',buyer_confirmed=1,seller_confirmed=0,review_note=null where id=d.id;
 elsif p_action='seller-approve' then
 if m.id<>d.seller or d.stage<>'seller_review' then raise exception 'Only the seller can review submitted payment proof.';end if;
 update vm.deals set stage='midman_review',seller_confirmed=1 where id=d.id;
 elsif p_action='revision' then
 if (m.id=d.seller and d.stage='seller_review') or (m.id=d.midman and d.stage='midman_review') then
 note:=trim(coalesce(p_data->>'note',''));if length(note) not between 5 and 1000 then raise exception 'Explain what needs to be corrected.';end if;
 update vm.deals set stage='revision',buyer_confirmed=0,seller_confirmed=0,review_note=note where id=d.id;
 else raise exception 'You cannot request revision at this stage.';end if;
 elsif p_action='complete' then
 if m.id is distinct from d.midman or d.stage<>'midman_review' or d.seller_confirmed<>1 or d.buyer_confirmed<>1 then raise exception 'Assigned Midman confirms last, after buyer proof and seller approval.';end if;
 if not exists(select 1 from vm.members mm where mm.id=m.id and mm.role='midman') then raise exception 'Verified Midman role required.';end if;
 update vm.deals set stage='complete',midman_confirmed=1 where id=d.id;
 elsif p_action='cancel' then
 if m.id<>d.seller or d.stage<>'awaiting_payment' then raise exception 'Only the seller can cancel before payment proof is submitted.';end if;
 delete from vm.deals where id=d.id;
 else raise exception 'Unknown transaction action.';end if;
 end if;
 return jsonb_build_object('ok',true);
end;$$;
revoke all on function public.vm_trade(text,jsonb) from public,anon;
grant execute on function public.vm_trade(text,jsonb) to authenticated;

create or replace function vm.public_member(m vm.members) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',m.id,'role',m.role,'admin',exists(select 1 from auth.users u join vm.admin_emails a on lower(u.email)=a.email where u.id=m.id and u.email_confirmed_at is not null),'credits',case when m.suspended_until<=now() then 25 else m.credits end,'suspended',coalesce(m.suspended_until>now(),false),'sales',(select count(*) from vm.external_sales e where e.seller=m.id)+(select count(*) from vm.deals d where d.seller=m.id and d.seller_confirmed=1 and d.buyer_confirmed=1 and (d.midman is null or d.midman_confirmed=1)),'midmanDeals',(select count(*) from vm.deals d where d.midman=m.id and d.seller_confirmed=1 and d.buyer_confirmed=1 and d.midman_confirmed=1),'confirmedReports',(select count(*) from vm.reports r where r.target=m.id and r.status='confirmed'));
$$;
create or replace function public.vm_read(p_scope text default 'market') returns jsonb language plpgsql security definer set search_path='' as $$
declare m vm.members;u auth.users;admin boolean:=false;out_records jsonb;out_members jsonb;member_json jsonb;
begin
 if auth.uid() is not null then m:=vm.ensure_member();select * into u from auth.users where id=auth.uid();admin:=vm.is_admin();end if;
 member_json:=case when m.id is null then null else jsonb_build_object('id',m.id,'role',m.role,'credits',m.credits,'suspended',coalesce(m.suspended_until>now(),false),'suspendedUntil',m.suspended_until,'admin',admin) end;
 if m.suspended_until>now() then
  if p_scope='trust' then return jsonb_build_object('member',member_json,'members','[]'::jsonb,'deals','[]'::jsonb,'reports','[]'::jsonb,'requests','[]'::jsonb);end if;
  return jsonb_build_object('records','[]'::jsonb,'user',jsonb_build_object('id',m.id,'name',coalesce(u.raw_user_meta_data->>'full_name',u.email),'suspended',true,'suspendedUntil',m.suspended_until));
 end if;
 if p_scope='trust' then
  select coalesce(jsonb_agg(vm.public_member(mm)),'[]'::jsonb) into out_members from vm.members mm;
  return jsonb_build_object('member',member_json,'members',out_members,'deals',coalesce((select jsonb_agg(to_jsonb(d) order by d.created desc) from vm.deals d where auth.uid() in (d.seller,d.buyer,d.midman)),'[]'::jsonb),'reports',coalesce((select jsonb_agg(to_jsonb(r) order by r.created desc) from vm.reports r where admin or r.reporter=auth.uid()),'[]'::jsonb),'requests',coalesce((select jsonb_agg(to_jsonb(r) order by r.created desc) from vm.role_requests r where admin or r.member=auth.uid()),'[]'::jsonb));
 end if;
 select coalesce(jsonb_agg(q.obj order by q.created desc),'[]'::jsonb) into out_records from (
 select r.created,r.data||jsonb_build_object('id',r.id,'kind',r.kind,'owner',r.owner,'created',r.created,'sold',vm.is_sold(r.id)) as obj
 from vm.records r left join vm.members mm on mm.id=r.owner where (mm.suspended_until is null or mm.suspended_until<=now()) and (r.kind<>'inquiry' or r.owner=auth.uid() or r.data->>'sellerId'=auth.uid()::text) order by r.created desc limit 1000) q;
 return jsonb_build_object('records',out_records,'user',case when m.id is null then null else jsonb_build_object('id',m.id,'name',coalesce((select r.data->>'name' from vm.records r where r.owner=m.id and r.kind='profile' order by r.created desc limit 1),u.raw_user_meta_data->>'full_name',u.email),'role',m.role,'credits',m.credits,'admin',admin) end);
end;$$;
create or replace function public.vm_write(p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare m vm.members;u auth.users;admin boolean;rec vm.records;rep vm.reports;rr vm.role_requests;deal vm.deals;target vm.members;buyer vm.members;mid vm.members;payload jsonb;clean jsonb:='{}';inv jsonb:='{}';kind text;k text;ids jsonb;v text;phone text;newid uuid:=gen_random_uuid();email text;fb text;
begin
 m:=vm.ensure_member();if m.suspended_until>now() then raise exception 'Your account is temporarily suspended.' using errcode='42501';end if;
 admin:=vm.is_admin();select * into u from auth.users where id=m.id;
 if p_action='save-record' then
  kind:=p_data->>'kind';payload:=p_data->'data';if kind not in ('listing','profile','post','reply','inquiry') or jsonb_typeof(payload)<>'object' then raise exception 'Invalid record.';end if;
  if kind='listing' then
   if m.role not in ('seller','midman') and not admin then raise exception 'Request Seller approval in your profile before publishing.' using errcode='42501';end if;
   select r.* into rec from vm.records r where r.owner=m.id and r.kind='profile' order by r.created desc limit 1;
   if rec.id is null or coalesce(rec.data->>'email','')='' or coalesce(rec.data->>'facebook','')='' or coalesce(rec.data->>'whatsapp','')='' then raise exception 'Complete your Facebook, email, and WhatsApp profile first.';end if;
   if length(trim(coalesce(payload->>'title','')))<1 or coalesce(payload->>'price','')='' or (payload->>'price')::numeric<=0 or (payload->>'price')::numeric>10000000 then raise exception 'Enter a title and valid price.';end if;
   if coalesce(payload->>'level','')='' or coalesce(payload->>'region','') not in ('APAC','EU','NA') or (payload->>'level')::integer not between 1 and 9999 or coalesce(payload->>'rank','') not in ('Iron','Bronze','Silver','Gold','Platinum','Diamond','Ascendant','Immortal','Radiant') then raise exception 'Enter valid account details.';end if;
   foreach k in array array['weapons','cards','buddies','sprays'] loop
    ids:=payload->'inventory'->k;if jsonb_typeof(ids) is distinct from 'array' or jsonb_array_length(ids)>2000 then raise exception 'Select a valid account collection.';end if;
    if exists(select 1 from jsonb_array_elements_text(ids) a(value) where not exists(select 1 from vm.catalog c where c.category=k and c.id::text=a.value)) then raise exception 'An inventory selection is invalid.';end if;
    select coalesce(jsonb_agg(distinct a.value),'[]'::jsonb) into ids from jsonb_array_elements_text(ids) a(value);inv:=inv||jsonb_build_object(k,ids);
   end loop;
   foreach k in array array['title','price','rank','region','level','description','image'] loop clean:=clean||jsonb_build_object(k,left(trim(coalesce(payload->>k,'')),case when k='description' then 3000 else 250 end));end loop;
   if clean->>'image'<>'' and clean->>'image' !~ '^https://media\.valorant-api\.com/' then raise exception 'Invalid skin image.';end if;
   clean:=clean||jsonb_build_object('inventory',inv,'skins',jsonb_array_length(inv->'weapons'),'urgency',case when payload->>'urgency'='rush' then 'rush' else 'normal' end,'contact','Use seller profile contact channels');
  elsif kind='profile' then
   email:=trim(coalesce(payload->>'email',''));fb:=trim(coalesce(payload->>'facebook',''));phone:=regexp_replace(coalesce(payload->>'whatsapp',''),'[[:space:]()+-]','','g');
   if phone~'^09[0-9]{9}$' then phone:='63'||substring(phone from 2);end if;
   if length(trim(coalesce(payload->>'name','')))=0 or email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or length(email)>250 or fb !~ '^https://(www\.|m\.)?(facebook\.com|fb\.com)/[^[:space:]]*$' or length(fb)>250 or phone!~'^[1-9][0-9]{7,14}$' then raise exception 'Enter a display name, valid email, HTTPS Facebook URL, and WhatsApp number with country code.';end if;
   clean:=jsonb_build_object('name',left(trim(payload->>'name'),100),'bio',left(coalesce(payload->>'bio',''),2000),'facebook',fb,'email',email,'whatsapp',phone);
  elsif kind='post' then
   if length(trim(coalesce(payload->>'title','')))=0 or length(trim(coalesce(payload->>'message','')))=0 or payload->>'category' not in ('Selling','Collections','Discussion','Community') then raise exception 'Complete the title, category, and message.';end if;
   clean:=jsonb_build_object('title',left(payload->>'title',150),'message',left(payload->>'message',3000),'category',payload->>'category');
  elsif kind='inquiry' then
   select r.* into rec from vm.records r where r.id=(payload->>'listingId')::uuid and r.kind='listing';if rec.id is null or rec.owner=m.id then raise exception 'Choose a listing from another seller.';end if;
   if length(trim(coalesce(payload->>'message','')))=0 then raise exception 'Enter your inquiry.';end if;
   clean:=jsonb_build_object('listingId',rec.id,'sellerId',rec.owner,'message',left(payload->>'message',3000));
  else
   if coalesce(payload->>'postId','') not in ('topic-1','topic-2','topic-3') and not exists(select 1 from vm.records r where r.id::text=payload->>'postId' and r.kind='post') then raise exception 'Discussion not found.';end if;
   if length(trim(coalesce(payload->>'message','')))=0 then raise exception 'Enter a reply.';end if;
   clean:=jsonb_build_object('postId',payload->>'postId','message',left(payload->>'message',3000));
  end if;
  clean:=clean||jsonb_build_object('author',coalesce((select r.data->>'name' from vm.records r where r.owner=m.id and r.kind='profile' order by r.created desc limit 1),u.raw_user_meta_data->>'full_name',u.email));
  insert into vm.records(id,kind,owner,data) values(newid,kind,m.id,clean);
 elsif p_action='delete-record' then
  if exists(select 1 from vm.conversations c where c.listing=(p_data->>'id')::uuid) or exists(select 1 from vm.deals d where d.listing=(p_data->>'id')::uuid) or exists(select 1 from vm.external_sales e where e.listing=(p_data->>'id')::uuid) then raise exception 'Listings with interested buyers or sale history cannot be deleted.';end if;
  select * into rec from vm.records where id=(p_data->>'id')::uuid and owner=m.id;
  if rec.id is null then raise exception 'Record not found or not owned by you.' using errcode='42501';end if;
  if exists(select 1 from vm.deals d where d.listing=rec.id) or exists(select 1 from vm.reports r where r.listing=rec.id) then raise exception 'A listing with transaction or report history cannot be deleted.';end if;
  delete from vm.records where id=rec.id;
 elsif p_action='request-role' then
  if p_data->>'role' not in ('seller','midman') or length(trim(coalesce(p_data->>'details','')))<10 then raise exception 'Choose a role and describe your experience.';end if;
  insert into vm.role_requests(member,role,details) values(m.id,p_data->>'role',left(p_data->>'details',2000));
 elsif p_action='review-role' then
  if not admin then raise exception 'Administrator access required.' using errcode='42501';end if;
  select * into rr from vm.role_requests where id=(p_data->>'id')::uuid for update;
  if rr.id is null or rr.status<>'pending' or p_data->>'decision' not in ('approved','rejected') then raise exception 'Request is unavailable or already reviewed.';end if;
  if p_data->>'decision'='approved' then update vm.members set role=rr.role where id=rr.member;end if;
  update vm.role_requests set status=p_data->>'decision' where id=rr.id;
 elsif p_action='report' then
  select r.* into rec from vm.records r where r.id=(p_data->>'listingId')::uuid and r.kind='listing';
  if rec.id is null or rec.owner=m.id then raise exception 'Choose a listing from another seller.';end if;
  if length(trim(coalesce(p_data->>'reason','')))<10 or length(trim(coalesce(p_data->>'evidence','')))<10 then raise exception 'Provide the concern and supporting evidence.';end if;
  insert into vm.reports(reporter,target,listing,reason,evidence) values(m.id,rec.owner,rec.id,left(p_data->>'reason',2000),left(p_data->>'evidence',3000));
 elsif p_action='review-report' then
  if not admin then raise exception 'Administrator access required.' using errcode='42501';end if;
  select * into rep from vm.reports where id=(p_data->>'id')::uuid for update;
  if rep.id is null or rep.status<>'pending' or p_data->>'decision' not in ('confirmed','dismissed') then raise exception 'Report is unavailable or already reviewed.';end if;
  if p_data->>'decision'='confirmed' then
   insert into vm.members(id) values(rep.target) on conflict do nothing;
   select * into target from vm.members where id=rep.target for update;
   if target.suspended_until is not null and target.suspended_until<=now() then target.credits:=25;target.suspended_until:=null;end if;
   target.credits:=greatest(0,target.credits-25);
   update vm.members set credits=target.credits,suspended_until=case when target.credits=0 then now()+interval '7 days' else target.suspended_until end where id=target.id;
  end if;
  update vm.reports set status=p_data->>'decision',reviewer=m.id where id=rep.id;
 elsif p_action='create-deal' then
  raise exception 'Use the transaction panel to choose an interested buyer and verified Midman.';

  if m.role not in ('seller','midman') and not admin then raise exception 'An approved Seller or Midman role is required.' using errcode='42501';end if;
  select r.* into rec from vm.records r where r.id=(p_data->>'listingId')::uuid and r.kind='listing' and r.owner=m.id;
  select * into buyer from vm.members where id=(p_data->>'buyer')::uuid;
  if rec.id is null or buyer.id is null or buyer.id=m.id or buyer.suspended_until>now() then raise exception 'Choose your listing and an active buyer member ID.';end if;
  if coalesce(p_data->>'midman','')<>'' then
   select * into mid from vm.members where id=(p_data->>'midman')::uuid and role='midman';
   if mid.id is null or mid.id in (buyer.id,m.id) or mid.suspended_until>now() then raise exception 'Choose an active approved Midman distinct from buyer and seller.';end if;
  end if;
  insert into vm.deals(listing,seller,buyer,midman) values(rec.id,m.id,buyer.id,mid.id);
 elsif p_action='confirm-deal' then
  select * into deal from vm.deals where id=(p_data->>'id')::uuid for update;
  if deal.stage<>'legacy' then raise exception 'Use the ordered transaction review buttons.';end if;
  if deal.id is null or (m.id is distinct from deal.buyer and m.id is distinct from deal.midman) then raise exception 'Only the assigned buyer or midman can confirm.' using errcode='42501';end if;
  update vm.deals d set buyer_confirmed=case when d.buyer=m.id then 1 else d.buyer_confirmed end,midman_confirmed=case when d.midman=m.id then 1 else d.midman_confirmed end where d.id=deal.id;
 elsif p_action='cancel-deal' then
  delete from vm.deals where id=(p_data->>'id')::uuid and seller=m.id and buyer_confirmed=0 and midman_confirmed=0 and stage='legacy';
 else raise exception 'Unknown action.';end if;
 return jsonb_build_object('ok',true,'id',newid);
exception when unique_violation then return jsonb_build_object('error','This report, pending role request, or listing transaction already exists.');when invalid_text_representation then return jsonb_build_object('error','Enter valid account values and member IDs.');end;$$;
create or replace function public.vm_chat(p_action text,p_data jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare m vm.members; other vm.members; r vm.records; c vm.conversations; msg_id bigint; new_thread boolean; contact_channel text; body text; cursor_id bigint;
begin
 m:=vm.ensure_member();
 if m.suspended_until>now() then raise exception 'Your account is temporarily suspended.' using errcode='42501';end if;
 if p_action='inbox' then
 return jsonb_build_object('threads',coalesce((select jsonb_agg(x.obj order by x.latest desc) from (
 select coalesce((select max(mm.id) from vm.messages mm where mm.conversation=cc.id),0) latest,
 to_jsonb(cc)||jsonb_build_object('title',rr.data->>'title','price',rr.data->>'price','sold',exists(select 1 from vm.deals d where d.listing=cc.listing and d.buyer_confirmed=1 and (d.midman is null or d.midman_confirmed=1)),
 'peerName',coalesce((select pr.data->>'name' from vm.records pr where pr.kind='profile' and pr.owner=case when cc.buyer=m.id then cc.seller else cc.buyer end order by pr.created desc limit 1),'Marketplace member'),
 'lastMessage',(select mm.body from vm.messages mm where mm.conversation=cc.id order by mm.id desc limit 1),
 'unread',(select count(*) from vm.messages mm where mm.conversation=cc.id and mm.sender<>m.id and mm.id>case when cc.buyer=m.id then cc.buyer_seen else cc.seller_seen end)) obj
 from vm.conversations cc join vm.records rr on rr.id=cc.listing where m.id in (cc.buyer,cc.seller)) x),'[]'::jsonb));
 elsif p_action='interest' then
 contact_channel:=coalesce(p_data->>'channel','website');
 if contact_channel not in ('website','whatsapp','facebook','email','copy') then raise exception 'Invalid contact channel.';end if;
 select * into r from vm.records where id=(p_data->>'listingId')::uuid and kind='listing';
 if r.id is null or r.owner=m.id then raise exception 'Choose an account from another seller.';end if;
 select * into other from vm.members where id=r.owner;
 if other.id is null or other.suspended_until>now() then raise exception 'Seller is unavailable.';end if;
 if vm.is_sold(r.id) then raise exception 'This account has already been sold.';end if;
 insert into vm.conversations(listing,buyer,seller,channel) values(r.id,m.id,r.owner,contact_channel) on conflict do nothing returning * into c;
 new_thread:=c.id is not null;
 if not new_thread then select * into c from vm.conversations where listing=r.id and buyer=m.id for update;end if;
 if new_thread then
 insert into vm.messages(conversation,sender,body) values(c.id,m.id,'Hi! I am interested in '||left(r.data->>'title',250)||'. Is it still available? Contact preference: '||contact_channel||'.') returning id into msg_id;
 update vm.conversations set buyer_seen=msg_id where id=c.id;
 elsif c.channel<>contact_channel then update vm.conversations set channel=contact_channel where id=c.id;end if;
 return jsonb_build_object('threadId',c.id,'created',new_thread);
 else
 select * into c from vm.conversations where id=(p_data->>'threadId')::uuid for update;
 if c.id is null or m.id not in(c.buyer,c.seller) then raise exception 'Conversation unavailable.' using errcode='42501';end if;
 if p_action='messages' then
 cursor_id:=greatest(coalesce((p_data->>'before')::bigint,9223372036854775807),1);
 return jsonb_build_object('messages',coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from (select mm.* from vm.messages mm where mm.conversation=c.id and mm.id<cursor_id order by mm.id desc limit 100) x),'[]'::jsonb));
 elsif p_action='seen' then
 -- Client supplies the last message actually displayed, avoiding unread races.
 select coalesce(max(id),0) into msg_id from vm.messages where conversation=c.id and id<=coalesce((p_data->>'lastId')::bigint,0);
 if m.id=c.buyer then update vm.conversations set buyer_seen=greatest(buyer_seen,msg_id) where id=c.id;
 else update vm.conversations set seller_seen=greatest(seller_seen,msg_id) where id=c.id;end if;
 return jsonb_build_object('ok',true);
 elsif p_action='send' then
 select * into other from vm.members where id=case when m.id=c.buyer then c.seller else c.buyer end;
 if other.suspended_until>now() then raise exception 'This member is temporarily unavailable.';end if;
 body:=trim(coalesce(p_data->>'body',''));
 if length(body) not between 1 and 3000 then raise exception 'Enter a message up to 3,000 characters.';end if;
 if exists(select 1 from vm.messages mm where mm.sender=m.id and mm.created>now()-interval '1 second') then raise exception 'Please wait a moment before sending another message.';end if;
 insert into vm.messages(conversation,sender,body) values(c.id,m.id,body) returning id into msg_id;
 return jsonb_build_object('ok',true,'id',msg_id);
 else raise exception 'Unknown chat action.';end if;
 end if;
end;$$;
commit;
