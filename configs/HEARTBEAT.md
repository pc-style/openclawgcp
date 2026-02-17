# OpenClaw Heartbeat — All Workflows

## System Behavior

**Timezone:** Europe/Warsaw (CET/CEST)
**Notification Channel:** Telegram only
**Daily Alert Cap:** Max 6 proactive notifications per day
**LLM:** Gemini 2.0 Flash (fallback: Gemini 1.5 Pro)
**Search:** Perplexity Sonar Reasoning Pro

---

## 1. DAILY BRIEF (7:00 AM CET)

**Trigger:** Cron `0 7 * * *`

**Execution Flow:**

```python
async def daily_brief():
    # 1. GATHER DATA
    today = get_date("Europe/Warsaw")
    tomorrow = today + timedelta(days=1)
    
    # Calendar
    today_events = await calendar.list_events(today, today + timedelta(days=1))
    tomorrow_events = await calendar.list_events(tomorrow, tomorrow + timedelta(days=1))
    
    # Check shared calendars too (findAvailableTimes equivalent)
    all_calendars = await calendar.get_all_calendars()
    for cal in all_calendars:
        today_events += await calendar.list_events(today, today + timedelta(days=1), calendar_id=cal.id)
    
    # Email
    inbox = await gmail.search({
        "after": (today - timedelta(days=2)).isoformat(),
        "onlyUnread": False,
        "excludeArchived": True
    })
    
    important_emails = []
    for email in inbox:
        score = score_email_importance(email)
        if score >= 3:  # Threshold for daily brief
            important_emails.append(email)
    
    # Yesterday's meetings
    yesterday = today - timedelta(days=1)
    yesterday_meetings = await meetings.search({
        "startDate": yesterday.isoformat(),
        "endDate": today.isoformat()
    })
    
    loose_ends = []
    for meeting in yesterday_meetings:
        details = await meetings.get_info(meeting.id)
        if details.action_items:
            for item in details.action_items:
                if not item.completed:
                    loose_ends.append({
                        "meeting": meeting.name,
                        "item": item.description,
                        "owner": item.owner
                    })
    
    # Reminders
    reminders = await get_active_reminders()
    
    # Weather (Warsaw)
    weather = await perplexity.query("Current weather in Warsaw, Poland today")
    
    # News
    news = await perplexity.query(
        "Latest AI, tech, and dev tools news from the past 24 hours",
        search_recency_filter="day"
    )
    
    # 2. SCAN FOR PATTERNS
    patterns = []
    
    # Aging emails
    for email in important_emails:
        age_hours = (today - email.received_at).total_seconds() / 3600
        if age_hours > 24 and email.from_important_sender:
            patterns.append({
                "type": "aging_email",
                "email": email,
                "age_hours": age_hours
            })
    
    # Meeting + related email
    for event in today_events:
        for email in important_emails:
            if any(attendee in email.participants for attendee in event.attendees):
                patterns.append({
                    "type": "meeting_email_connection",
                    "meeting": event,
                    "email": email
                })
    
    # Conflicts
    for i, event1 in enumerate(today_events):
        for event2 in today_events[i+1:]:
            if events_overlap(event1, event2):
                patterns.append({
                    "type": "conflict",
                    "event1": event1,
                    "event2": event2
                })
    
    # Back-to-back with no break
    for i in range(len(today_events) - 1):
        if today_events[i].end == today_events[i+1].start:
            duration = (today_events[i+1].end - today_events[i].start).total_seconds() / 3600
            if duration >= 2:
                patterns.append({
                    "type": "no_break",
                    "events": [today_events[i], today_events[i+1]],
                    "duration_hours": duration
                })
    
    # 3. GENERATE PROACTIVE SUGGESTION
    suggestion = generate_proactive_suggestion(patterns, loose_ends, important_emails, today_events)
    
    # 4. ASSEMBLE MESSAGE
    message = f"""morning ☀️ here's your day

🌤️ warsaw - {weather}

📅 today:"""
    
    if not today_events:
        message += "\n• clear calendar"
    else:
        for event in today_events:
            attendees = ", ".join([a.name or a.email for a in event.attendees if a.email != "adam00krupa@gmail.com"])
            context = get_meeting_context(event)
            message += f"\n• {event.start.strftime('%I:%M%p').lower()} - {event.summary}"
            if attendees:
                message += f" w/ {attendees}"
            if context:
                message += f" ({context})"
    
    if important_emails:
        message += "\n\n📬 inbox:"
        for email in important_emails[:5]:  # Top 5
            message += f"\n• {email.subject} (from {email.from_name})"
    
    if loose_ends:
        message += "\n\n🔗 from yesterday:"
        for item in loose_ends[:3]:
            message += f"\n• {item['item']} (from {item['meeting']})"
    
    if reminders:
        message += "\n\n🔔 reminders:"
        for reminder in reminders:
            message += f"\n• {reminder.description}"
    
    if tomorrow_events and any(e.start.hour < 9 for e in tomorrow_events):
        message += "\n\n📅 tomorrow heads-up:"
        early = [e for e in tomorrow_events if e.start.hour < 9]
        for event in early:
            message += f"\n• {event.start.strftime('%I:%M%p').lower()} {event.summary} (early one)"
    
    if news:
        message += f"\n\n📰 {news[:200]}..."
    
    message += f"\n\n💡 {suggestion}"
    
    # 5. SEND
    await telegram.send_message(message)
    
    # 6. LOG
    await log_daily_brief_sent(today)

def score_email_importance(email):
    score = 0
    
    # Time-sensitive
    if "urgent" in email.subject.lower() or "asap" in email.subject.lower():
        score += 3
    if email.has_deadline_today():
        score += 3
    
    # Important sender
    important_senders = ["mateusz@terapeutaoddechu.pl", "investor", "client"]
    if any(sender in email.from_email.lower() for sender in important_senders):
        score += 2
    
    # Contract/legal
    if any(word in email.subject.lower() for word in ["contract", "nda", "agreement", "invoice"]):
        score += 2
    
    # Real person
    if not email.is_automated:
        score += 1
    
    # Active thread
    if email.thread_length > 3:
        score += 1
    
    # Noise penalties
    if email.is_promotional:
        score -= 3
    if email.is_newsletter:
        score -= 2
    if email.from_email.startswith("noreply"):
        score -= 3
    
    return score

def generate_proactive_suggestion(patterns, loose_ends, emails, events):
    # Priority: connect specific data points
    
    # Aging email + meeting today
    for pattern in patterns:
        if pattern["type"] == "meeting_email_connection":
            email = pattern["email"]
            meeting = pattern["meeting"]
            return f"you have an email from {email.from_name} about {email.subject[:30]}... and you're meeting them at {meeting.start.strftime('%I%p').lower()}. want me to pull up the thread before the call?"
    
    # Aging contract + meeting
    for email in emails:
        if "contract" in email.subject.lower():
            age_days = (datetime.now() - email.received_at).days
            for event in events:
                if any(email.from_email in a.email for a in event.attendees):
                    return f"that {email.subject.lower()} has been sitting since {age_days} days ago and you're meeting {event.attendees[0].name} at {event.start.strftime('%I%p').lower()}. want me to do a red flag sweep before the call?"
    
    # Back-to-back with no break
    for pattern in patterns:
        if pattern["type"] == "no_break" and pattern["duration_hours"] >= 3:
            return f"you have back-to-back from {pattern['events'][0].start.strftime('%I%p').lower()}-{pattern['events'][-1].end.strftime('%I%p').lower()} with no break. want me to push one by 30min so you can eat?"
    
    # Loose end + deadline today
    for item in loose_ends:
        if "due today" in item["item"].lower():
            return f"{item['item']} and you haven't started. want me to block an hour this morning?"
    
    # Default: calendar-based
    if len(events) >= 4:
        return "packed day with 4+ meetings. want me to move anything non-urgent to tomorrow?"
    
    if not events:
        return "clear calendar today. want me to block focus time before meetings pile up?"
    
    return "let me know if you need anything prepped for today's meetings"
```

## 2. PRODUCT HUNT BRIEF (2:55 PM CET)

**Trigger:** Cron `55 14 * * *`

**Execution Flow:**

```python
async def product_hunt_brief():
    # 1. CONSTRUCT URL
    today = get_date("Europe/Warsaw")
    # Format: https://www.producthunt.com/leaderboard/daily/YYYY/M/D
    # NO leading zeros for single-digit months/days
    url = f"https://www.producthunt.com/leaderboard/daily/{today.year}/{today.month}/{today.day}"
    
    # 2. SCRAPE PAGE
    html = await browser.goto(url)
    products = parse_product_hunt_html(html)
    
    # 3. FILTER DEV + AI ONLY
    dev_ai_products = []
    for product in products:
        categories = product.get("topics", [])
        if any(cat.lower() in ["developer tools", "artificial intelligence", "ai", "dev tools", "open source", "api", "saas"] for cat in categories):
            dev_ai_products.append(product)
    
    # 4. LOAD PREFERENCE PROFILE
    preferences = await load_memory("product_hunt_preferences")
    
    # 5. CATEGORIZE WITH LLM
    prompt = f"""You are analyzing Product Hunt launches for Adam, a developer interested in AI and dev tools.

Adam's past preferences:
{json.dumps(preferences, indent=2)}

Today's products:
{json.dumps(dev_ai_products, indent=2)}

Categorize each product into ONE of these categories:

1. **ULTRA HYPE** - Genuinely exciting, innovative, game-changing. Adam would want to try this immediately.
2. **MAYBE hype** - Interesting but not groundbreaking. Worth a look but not urgent.
3. **prob boring but i liked it** - Technical merit or interesting approach, but might not excite Adam.

Return JSON:
{{
  "ultra_hype": [{{ "name": "...", "tagline": "...", "url": "...", "reason": "why it's exciting" }}],
  "maybe_hype": [...],
  "prob_boring": [...]
}}
"""
    
    categorized = await gemini.generate(prompt, response_format="json")
    
    # 6. ASSEMBLE MESSAGE
    message = f"""🚀 product hunt brief — {today.strftime('%b %d')}

🔥 ULTRA HYPE:"""
    
    for product in categorized["ultra_hype"][:3]:
        message += f"\n• {product['name']} - {product['tagline']}\n  {product['url']}\n  💡 {product['reason']}"
    
    message += "\n\n🤔 MAYBE hype:"
    for product in categorized["maybe_hype"][:3]:
        message += f"\n• {product['name']} - {product['tagline']}\n  {product['url']}"
    
    message += "\n\n🤓 prob boring but i liked it:"
    for product in categorized["prob_boring"][:2]:
        message += f"\n• {product['name']} - {product['tagline']}\n  {product['url']}"
    
    message += "\n\nreply with 👍/👎 on any to help me learn what you like"
    
    # 7. SEND
    await telegram.send_message(message)
    
    # 8. SAVE FOR LEARNING
    await save_to_workspace("product_hunt_history", {
        "date": today.isoformat(),
        "products": categorized,
        "url": url
    })

# FEEDBACK LEARNING
async def handle_product_hunt_feedback(message):
    # User replies with 👍 or 👎 to a product
    if message.reply_to_message:
        product_name = extract_product_name(message.reply_to_message.text)
        reaction = "positive" if "👍" in message.text else "negative"
        
        preferences = await load_memory("product_hunt_preferences")
        preferences["feedback"].append({
            "product": product_name,
            "reaction": reaction,
            "date": datetime.now().isoformat()
        })
        
        await save_memory("product_hunt_preferences", preferences)
        await telegram.send_message("noted! I'll adjust future recommendations 👍")
```

## 3. EMAIL TRIAGE (Continuous)

**Trigger:** Gmail webhook (new email received)

**Execution Flow:**

```python
async def triage_email(email):
    # 1. SCORE IMPORTANCE
    score = score_email_importance(email)
    
    # 2. ASSIGN LABEL
    label = determine_label(email)
    await gmail.add_label(email.id, label)
    
    # 3. DECIDE IF ALERT NEEDED
    alerts_today = await count_alerts_today()
    
    if score >= 5 and alerts_today < 6:
        # Send Telegram alert
        message = f"""🚨 urgent email

from: {email.from_name} ({email.from_email})
subject: {email.subject}

{email.body[:300]}...

want me to draft a reply?"""
        
        await telegram.send_message(message)
        await increment_alert_count()
    
    elif score >= 3:
        # Include in next daily brief
        await add_to_daily_brief_queue(email)
    
    # 4. LOG
    await log_triage({
        "email_id": email.id,
        "score": score,
        "label": label,
        "alerted": score >= 5 and alerts_today < 6
    })

def determine_label(email):
    # Use LLM to classify
    prompt = f"""Classify this email into ONE label:

Labels:
- FYI: Informational, no reply needed
- To Respond: Requires action from Adam
- Newsletters: Subscribed content
- Notifications: System alerts about Adam's activity
- Invoices: Billing/payments
- Lindy: Emails from Lindy services
- Calendar: Meeting notifications
- Promotions: Marketing emails
- Comments: Document collaboration

Email:
From: {email.from_email}
Subject: {email.subject}
Body: {email.body[:500]}

Return only the label name."""
    
    return await gemini.generate(prompt, max_tokens=10)
```

## 4. MEETING PREP (15 min before external meetings)

**Trigger:** Calendar event starting in 15 minutes

**Execution Flow:**

```python
async def meeting_prep(event):
    # 1. CHECK IF EXTERNAL
    adam_domain = "gmail.com"
    external_attendees = [a for a in event.attendees if adam_domain not in a.email]
    
    if not external_attendees:
        return  # Skip internal meetings
    
    # 2. RESEARCH ATTENDEES
    attendee_info = []
    for attendee in external_attendees:
        info = await perplexity.query(
            f"Who is {attendee.name or attendee.email}? Current role, company, recent news.",
            search_mode="web"
        )
        attendee_info.append({
            "name": attendee.name or attendee.email,
            "info": info
        })
    
    # 3. EMAIL CONTEXT
    email_threads = []
    for attendee in external_attendees:
        emails = await gmail.search({
            "from": attendee.email,
            "maxResults": 5
        })
        email_threads.extend(emails)
    
    # 4. PAST MEETINGS
    past_meetings = await meetings.search({
        "attendeeEmail": external_attendees[0].email,
        "endDate": datetime.now().isoformat()
    })
    
    last_meeting = None
    open_items = []
    if past_meetings:
        last_meeting = past_meetings[0]
        details = await meetings.get_info(last_meeting.id)
        open_items = [item for item in details.action_items if not item.completed]
    
    # 5. VENUE INFO (if in-person)
    venue_info = None
    if event.location and "http" not in event.location:
        venue_info = await perplexity.query(
            f"Hours, parking, and details for {event.location}",
            search_mode="web"
        )
    
    # 6. PROACTIVE SUGGESTION
    suggestion = ""
    if open_items:
        suggestion = f"heads up, you owe {external_attendees[0].name} {len(open_items)} items from your last call: {', '.join([item.description[:30] for item in open_items])}. want me to draft those now?"
    elif email_threads:
        latest = email_threads[0]
        if (datetime.now() - latest.received_at).days > 3:
            suggestion = f"{external_attendees[0].name} emailed about {latest.subject} {(datetime.now() - latest.received_at).days} days ago and you haven't replied. want me to draft a response before the call?"
    
    # 7. ASSEMBLE MESSAGE
    message = f"""📋 {event.summary} — in 15 min

👤 {attendee_info[0]['name']}
{attendee_info[0]['info'][:200]}

📝 """
    
    if last_meeting:
        message += f"last met {last_meeting.meeting_date.strftime('%b %d')}"
        if open_items:
            message += f", {len(open_items)} open items"
    else:
        message += "first meeting"
    
    if email_threads:
        message += f"\n📧 recent thread: {email_threads[0].subject}"
    
    if venue_info:
        message += f"\n📍 {venue_info[:150]}"
    
    if suggestion:
        message += f"\n\n💡 {suggestion}"
    
    # 8. SEND
    await telegram.send_message(message)
```

## 5. MEETING RECORDING & SUMMARY

**Trigger:** Calendar event starts (if recording enabled)

**Execution Flow:**

```python
async def record_meeting(event):
    # 1. JOIN MEETING
    meeting_url = extract_meeting_url(event.description or event.location)
    if not meeting_url:
        return
    
    bot = await meeting_bot.join(meeting_url, name="Adam's Assistant")
    
    # 2. RECORD & TRANSCRIBE
    transcript = await bot.record_and_transcribe()
    
    # 3. GENERATE SUMMARY
    prompt = f"""Summarize this meeting transcript:

Transcript:
{transcript}

Format:
## Key Decisions
- [3-5 bullet points with bolded key phrases]

## Quotes
- "[Exact quote]" — [Speaker Name]

## Action Items
- [Who] owes [what] by [when]

## Proactive Suggestion
[One specific suggestion based on what Adam said in the meeting that he might not act on without a nudge. Quote him directly.]
"""
    
    summary = await gemini.generate(prompt)
    
    # 4. POST-MEETING ACTIONS (from settings)
    # Example: Post to Slack #eng-updates
    if event.should_post_to_slack:
        await slack.post_message(
            channel="#eng-updates",
            text=f"*Meeting Summary* — {event.summary}\n\n{summary}"
        )
    
    # 5. SEND SUMMARY
    await telegram.send_message(f"""📋 meeting summary — {event.summary}

{summary}

[View full transcript]({transcript_url})""")
    
    # 6. SAVE
    await save_to_workspace("meeting_transcripts", {
        "event_id": event.id,
        "date": event.start.isoformat(),
        "transcript": transcript,
        "summary": summary
    })
```

## 6. EMAIL DRAFTING

**Trigger:** User requests via Telegram

**Execution Flow:**

```python
async def draft_email(to, subject, context):
    # 1. LOAD TONE PREFERENCES
    tone = await load_memory("email_tone")  # "Professional external, casual internal"
    
    # 2. CHECK RECIPIENT TYPE
    is_external = "@gmail.com" not in to
    
    # 3. GENERATE DRAFT
    prompt = f"""Draft an email from Adam to {to}.

Subject: {subject}
Context: {context}

Tone: {"Professional but warm" if is_external else "Casual, friendly"}
Style:
- Proper capitalization (NOT lowercase SMS style)
- Short paragraphs (1-3 sentences)
- Contractions (I'm, I'd, we'll)
- Sign-off: {"Best" if is_external else "Thanks"}
- No filler phrases

Return only the email body."""
    
    draft = await gemini.generate(prompt)
    
    # 4. SHOW TO USER
    await telegram.send_message(f"""📧 draft email to {to}

Subject: {subject}

{draft}

reply "send" to send or edit as needed""")
    
    return draft

async def send_email(to, subject, body):
    await gmail.send({
        "to": to,
        "subject": subject,
        "body": body,
        "from": "adam00krupa@gmail.com"
    })
    
    await telegram.send_message(f"✅ sent to {to}")
```

## 7. CALENDAR MANAGEMENT

```python
async def find_available_times(attendees, duration_minutes, date_range):
    # 1. GET ALL CALENDARS (including shared)
    all_calendars = await calendar.get_all_calendars()
    
    # 2. COLLECT BUSY TIMES
    busy_times = []
    for cal in all_calendars:
        events = await calendar.list_events(
            date_range["start"],
            date_range["end"],
            calendar_id=cal.id
        )
        busy_times.extend([(e.start, e.end) for e in events])
    
    # 3. FIND GAPS
    available_slots = find_gaps(busy_times, duration_minutes)
    
    # 4. FILTER BY PREFERENCES
    # Mon-Sun 9am-5pm, max 4hrs meetings/day
    filtered = []
    for slot in available_slots:
        if 9 <= slot.start.hour < 17:  # 9am-5pm
            daily_meeting_hours = calculate_daily_meeting_hours(slot.start.date())
            if daily_meeting_hours + (duration_minutes / 60) <= 4:
                filtered.append(slot)
    
    return filtered[:5]  # Top 5 options

async def create_event(summary, start, duration_minutes, attendees):
    event = await calendar.create({
        "summary": summary,
        "start": start.isoformat(),
        "end": (start + timedelta(minutes=duration_minutes)).isoformat(),
        "attendees": [{"email": a} for a in attendees],
        "conferenceData": {
            "createRequest": {"requestId": str(uuid.uuid4())}
        }  # Auto-create Google Meet link
    })
    
    await telegram.send_message(f"✅ created: {summary} at {start.strftime('%I:%M%p %b %d')}")
    return event
```

## 8. LINEAR INTEGRATION

```python
async def create_linear_issue(title, description, project_id):
    issue = await linear.create_issue({
        "title": title,
        "description": description,
        "projectId": project_id,
        "teamId": os.getenv("LINEAR_TEAM_ID")
    })
    
    await telegram.send_message(f"✅ created Linear issue: {issue.identifier}\n{issue.url}")
    return issue

# Example: Create issue from meeting action item
async def meeting_action_to_linear(action_item, meeting_name):
    await create_linear_issue(
        title=f"[{meeting_name}] {action_item.description}",
        description=f"Action item from meeting: {meeting_name}\n\nOwner: {action_item.owner}\nDue: {action_item.due_date}",
        project_id=os.getenv("LINEAR_PROJECT_ID")
    )
```

## 9. PROACTIVE REMINDERS

```python
async def set_reminder(description, fire_at):
    reminder_id = str(uuid.uuid4())
    await save_to_workspace("reminders", {
        "id": reminder_id,
        "description": description,
        "fire_at": fire_at.isoformat(),
        "created_at": datetime.now().isoformat()
    })
    
    # Schedule timer
    await schedule_task(fire_at, reminder_callback, reminder_id)

async def reminder_callback(reminder_id):
    reminder = await load_from_workspace("reminders", reminder_id)
    
    # Check alert cap
    alerts_today = await count_alerts_today()
    if alerts_today >= 6:
        # Reschedule for tomorrow
        await set_reminder(reminder["description"], datetime.now() + timedelta(days=1))
        return
    
    await telegram.send_message(f"🔔 reminder: {reminder['description']}")
    await increment_alert_count()
    await mark_reminder_complete(reminder_id)
```

## 10. IMAGE GENERATION

```python
async def generate_image(prompt, reference_url=None):
    # Use Replicate Flux model
    params = {
        "prompt": prompt,
        "aspect_ratio": "16:9",
        "output_format": "png"
    }
    
    if reference_url:
        params["image"] = reference_url
        params["prompt"] = f"{prompt}, in the style of the reference image"
    
    result = await replicate.run(
        "black-forest-labs/flux-1.1-pro",
        input=params
    )
    
    image_url = result["output"][0]
    await telegram.send_photo(image_url)
    
    return image_url
```

## 11. WEB SCRAPING & RESEARCH

```python
async def scrape_url(url):
    html = await browser.goto(url)
    text = extract_text(html)
    return text

async def research_topic(query):
    result = await perplexity.query(
        query,
        model="sonar-reasoning-pro",
        search_mode="web",
        return_citations=True
    )
    return result
```

## 12. TELEGRAM COMMAND HANDLERS

```python
@telegram.command("/start")
async def start(message):
    await telegram.send_message("""hey adam 👋

I'm your AI assistant running on OpenClaw.

Commands:
/brief - get today's brief now
/ph - get today's Product Hunt brief
/draft [to] [subject] - draft an email
/remind [description] [when] - set a reminder
/find [attendees] [duration] - find meeting times
/research [query] - deep research

Or just message me naturally and I'll figure it out.""")

@telegram.command("/brief")
async def manual_brief(message):
    await daily_brief()

@telegram.command("/ph")
async def manual_ph(message):
    await product_hunt_brief()

@telegram.message_handler()
async def handle_message(message):
    # Natural language processing
    intent = await classify_intent(message.text)
    
    if intent == "draft_email":
        # Extract to, subject, context
        await draft_email(...)
    elif intent == "find_times":
        # Extract attendees, duration
        await find_available_times(...)
    elif intent == "research":
        result = await research_topic(message.text)
        await telegram.send_message(result)
    else:
        # General conversation
        response = await gemini.generate(f"User: {message.text}\n\nRespond as Adam's assistant:")
        await telegram.send_message(response)
```
