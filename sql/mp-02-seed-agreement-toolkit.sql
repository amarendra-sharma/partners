-- ============================================================================
--  MacroNations Partner Program — seed: partner agreement v1 + starter toolkit
--  Run after mp-01. Re-running does not duplicate rows.
--
--  IMPORTANT: Agreement v1 below is a DRAFT for counsel review. Partners cannot
--  sign anything until you switch "Agreements open" on in the admin console
--  (mp_settings.agreements_open), so it is safe to install now.
--  {{fields}} are filled in per partner at signing time.
-- ============================================================================

insert into mp_agreement_templates (kind, version, title, is_current, body)
select 'partner', 1, 'MacroNations Partner Agreement', true, $agr$
MACRONATIONS PARTNER AGREEMENT

This Partner Agreement (the "Agreement") is entered into on {{date}} between MacroNations LLC, a New York limited liability company ("MacroNations," "we," "us"), and {{partner_name}} ({{partner_email}}) ("Partner," "you").

## 1. Purpose
MacroNations operates online economics and finance courses and a learning platform for colleges and universities (the "Platform"). You will introduce the Platform to professors, departments and institutions ("Prospects") and help them adopt it. In return, you earn a share of the revenue from the courses you bring in, as set out below.

## 2. Relationship
2.1 You are an independent contractor. Nothing in this Agreement makes you an employee, agent, partner in a legal sense, or joint venturer of MacroNations. You may not sign contracts, make promises, or accept payment on our behalf.
2.2 This Agreement is non-exclusive. You may promote other products, and we may work with other partners and approach any Prospect directly.
2.3 You are responsible for your own expenses, equipment, taxes and insurance.

## 3. Definitions
3.1 "Registered Lead" means a professor you enter in the partner portal that we have not marked as a conflict or rejected.
3.2 "Adopted Course" means a course section on the Platform that (a) is created by a Registered Lead within {{protection_days}} days of registration (or any extension we grant in the portal), or that is created or purchased through your referral link or code, and (b) we confirm in the partner portal as credited to you.
3.3 "Net Revenue" means the amounts MacroNations actually receives for an Adopted Course (student purchases and any institutional fees), less refunds, chargebacks, payment-processing fees, and sales or similar taxes.
3.4 "Commission Period" means {{months}} months beginning on the date the Adopted Course is credited to you in the portal.

## 4. Commission
4.1 You earn {{rate}} of Net Revenue from each Adopted Course received during its Commission Period.
4.2 Once {{tier_threshold}} or more courses have been credited to you, each Adopted Course credited after that point earns {{tier_rate}}. Rates already applied to earlier Adopted Courses do not change.
4.3 We may agree a different rate with you for a specific deal. Any such rate will be shown on that course in the partner portal, and the portal record controls.
4.4 No commission is earned on: (a) Prospects we were already actively working with before your registration, which we will tell you about promptly after you register them; (b) revenue received after the Commission Period ends; (c) amounts later refunded or charged back (we may deduct these from future payments); or (d) any course covered by Section 6.3.
4.5 If two partners claim the same Prospect, we will decide credit in good faith, generally in favour of the earliest Registered Lead that led to the adoption. Our decision is final.

## 5. Statements and payment
5.1 Your earnings are shown in the partner portal as Pending, Approved, and Paid. We review and approve commissions monthly.
5.2 Approved commissions are paid within 30 days after the end of the month in which they are approved, once your balance reaches {{min_payout}}. Smaller balances carry forward.
5.3 Payments are made through Stripe Connect or another method we designate. You must complete the payee onboarding, including any tax information, before payments can be made. We will issue tax forms as required by law.
5.4 If you believe a statement is wrong, tell us within 60 days of it appearing in the portal. Otherwise it is final.

## 6. Conduct
6.1 You will describe the Platform accurately, using only materials we provide or approve, and will not make claims about pricing, features, results, or endorsements beyond those materials.
6.2 You will comply with all laws that apply to your activities, including anti-spam laws (such as CAN-SPAM) and anti-bribery laws. You will not offer or give any payment, gift, or other inducement to any professor, administrator, or institution to adopt the Platform.
6.3 If you are a faculty member, you are responsible for complying with your own institution's policies on outside activities and conflicts of interest. You will not earn commission on any course you teach yourself, or on any adoption you have authority to approve, unless you have disclosed it to us in writing and we have approved it in writing.
6.4 You will never receive, request, or store student records or student personal data. Prospects contract with MacroNations directly.

## 7. Brand and confidentiality
7.1 We grant you a limited, revocable, non-transferable licence to use the MacroNations name and materials solely to promote the Platform under this Agreement. You may not register domain names, social accounts, or ads using our name without our written consent.
7.2 You will keep confidential any non-public information we share with you (including pricing not yet published, pipeline information, and other partners' data) and use it only for this Agreement.

## 8. Term and termination
8.1 This Agreement starts on the date you sign and continues until either party ends it with 30 days' written notice (email is sufficient).
8.2 We may end it immediately if you materially breach it, including Sections 6 or 7.
8.3 After termination without cause, you continue to earn commission on Adopted Courses credited to you before the termination date until their Commission Periods end. After termination for cause, no further commission is earned.
8.4 Sections 4.4, 5, 7.2, 9 and 10 survive termination.

## 9. Changes to the program
We may change commission rates, tiers, or program rules for future adoptions with 30 days' notice in the partner portal or by email. Changes do not reduce the rate on Adopted Courses already credited to you.

## 10. General
10.1 Liability. Except for breach of Section 7 or amounts owed under Section 4, neither party is liable to the other for indirect or consequential damages, and our total liability under this Agreement is limited to the commissions paid or owed to you in the 12 months before the claim.
10.2 Governing law. This Agreement is governed by the laws of the State of New York, and the state and federal courts located in New York have exclusive jurisdiction.
10.3 Entire agreement. This Agreement, together with the terms shown in the partner portal, is the entire agreement between us on this subject. You may not assign it without our consent.
10.4 Electronic signature. By typing your name and clicking "Sign agreement," you agree to sign this Agreement electronically and agree that your electronic signature has the same effect as a handwritten signature. A copy is kept in your partner portal.
$agr$
where not exists (select 1 from mp_agreement_templates where kind = 'partner');

-- Starter toolkit (edit or replace from the admin console → Toolkit).
insert into mp_resources (kind, title, description, url, body, sort)
select * from (values
  ('demo', 'MacroNations course portal',
   'The live portal with all courses. Professors can browse every course before they commit.',
   'https://macronations.com', null, 10),
  ('email', 'Intro email to a professor',
   'Short first-touch email. Your personal link is filled in automatically.',
   null,
$t$Subject: A complete online course kit for {{course_taught}}

Dear Professor {{prof_last_name}},

I work with MacroNations, a platform built by economists for teaching economics and finance. It gives instructors a full course in one place: an interactive textbook, auto-graded quizzes and exams, simulation "arenas" students play, and a gradebook — at a low cost to students.

Many instructors use it alongside or instead of a traditional textbook. Setting up your own course section takes about ten minutes, and you can review everything first:

{{my_link}}

Would you be open to a 15-minute walkthrough? I'm happy to work around your schedule.

Best regards,
{{my_name}}$t$, 20),
  ('email', 'Follow-up after a demo',
   'Send within a day of a walkthrough.',
   null,
$t$Subject: Following up on MacroNations

Dear Professor {{prof_last_name}},

Thank you for your time today. As promised, here is the link to set up your own course section:

{{my_link}}

A few instructors start with a one-semester pilot in one section before rolling it out more broadly. If that would be useful, I can arrange it.

Please let me know if any questions come up.

Best regards,
{{my_name}}$t$, 30)
) v(kind, title, description, url, body, sort)
where not exists (select 1 from mp_resources);
