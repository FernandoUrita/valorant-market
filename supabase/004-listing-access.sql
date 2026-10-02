-- Run after 003-transactions.sql. Preserves all existing data.
begin;
create or replace function public.vm_trade(p_action text,p_data jsonb default '{}'::jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare m vm.members;r vm.records;d vm.deals;b uuid;mid uuid;proof text;name text;note text;
begin
 m:=vm.ensure_member();if m.suspended_until>now() then raise exception 'Your account is temporarily suspended.' using errcode='42501';end if;
 if p_action='read' then
 return jsonb_build_object('deals',coalesce((select jsonb_agg(to_jsonb(dd) order by dd.created desc) from vm.deals dd where m.id in(dd.buyer,dd.seller,dd.midman)),'[]'::jsonb),'interests',coalesce((select jsonb_agg(to_jsonb(c)) from vm.conversations c where c.seller=m.id or c.buyer=m.id),'[]'::jsonb),'applications',coalesce((select jsonb_agg(to_jsonb(a)) from vm.midman_applications a join vm.records rr on rr.id=a.listing where a.member=m.id or rr.owner=m.id),'[]'::jsonb),'outsideSales',coalesce((select jsonb_agg(to_jsonb(e)) from vm.external_sales e where e.seller=m.id),'[]'::jsonb));
 elsif p_action='admin-role' then
 if not vm.is_admin() or p_data->>'role' not in('seller','midman') then raise exception 'Administrator permission required.' using errcode='42501';end if;
 update vm.members set role=p_data->>'role' where id=m.id;return jsonb_build_object('ok',true);
 elsif p_action in ('apply','start','outside') then
 select * into r from vm.records where id=(p_data->>'listingId')::uuid and kind='listing' for update;
 if r.id is null or not exists(select 1 from vm.members sm where sm.id=r.owner and (sm.suspended_until is null or sm.suspended_until<=now())) or vm.is_sold(r.id) then raise exception 'Listing is unavailable or sold.';end if;
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
commit;
