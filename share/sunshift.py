#!/usr/bin/python3
"""Sunshift: night light on a schedule for the Omarchy bar."""
import argparse
import datetime as dt
import fcntl
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
from zoneinfo import ZoneInfo
import solar

CONFIG = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'sunshift'
STATE = Path(os.environ.get('XDG_STATE_HOME', Path.home() / '.local/state')) / 'sunshift'
DEFAULT = dict(morning='07:00', evening='20:00', day=6500, night=4000, transition=60,
               mode='manual', location=None, sunrise_offset=0, sunset_offset=0, auto_locate=False)
RELOCATE_EVERY, RELOCATE_RETRY = 12 * 3600, 15 * 60


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.tmp-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream, indent=2)
            stream.write('\n')
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def read_json(path, default):
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else default.copy()
    except (OSError, ValueError):
        return default.copy()


def minutes(value):
    if not isinstance(value, str) or not re.fullmatch(r'(?:[01]\d|2[0-3]):[0-5]\d', value):
        raise ValueError('Enter times as HH:MM, e.g. 07:00.')
    hour, minute = map(int, value.split(':'))
    return hour * 60 + minute


def validate(config):
    c = DEFAULT | config
    morning, evening = minutes(c['morning']), minutes(c['evening'])
    for key, lo, hi in [('day', 2500, 6500), ('night', 1800, 6500), ('transition', 5, 180)]:
        if type(c[key]) is not int or not lo <= c[key] <= hi:
            raise ValueError(f'{key}: Value must be between {lo} and {hi}.')
    if c['night'] > c['day']:
        raise ValueError('Night temperature must be lower than or equal to day temperature.')
    if min((evening - morning) % 1440, (morning - evening) % 1440) < c['transition']:
        raise ValueError('Transitions must not overlap. Move the start times further apart.')
    if c['mode'] not in ('manual', 'solar'):
        raise ValueError('Choose Manual times or Sun times.')
    if c['location'] is not None:
        c['location'] = solar.validate_location(c['location'])
    if c['mode'] == 'solar' and c['location'] is None:
        raise ValueError('Choose a location on the Location tab first.')
    if type(c['auto_locate']) is not bool:
        raise ValueError('Wi-Fi location must be on or off.')
    for key in ('sunrise_offset', 'sunset_offset'):
        if type(c[key]) is not int or not -360 <= c[key] <= 360 or c[key] % 30:
            raise ValueError('Offsets must be in 30-minute steps, between −6 and +6 hours.')
    return {key: c[key] for key in DEFAULT}


def load_config():
    return validate(read_json(CONFIG / 'config.json', DEFAULT))


def temperature(c, minute):
    """Smoothstep ramps start at morning/evening and wrap through midnight."""
    morning, evening = minutes(c['morning']), minutes(c['evening'])
    since_morning, since_evening = (minute - morning) % 1440, (minute - evening) % 1440
    daytime = since_morning < since_evening
    elapsed = since_morning if daytime else since_evening
    progress = min(1., elapsed / c['transition'])
    eased = progress * progress * (3 - 2 * progress)
    start, end = (c['night'], c['day']) if daytime else (c['day'], c['night'])
    return start + (end - start) * eased


def paused(state, now):
    until = state.get('until', 0)
    return isinstance(until, (int, float)) and (until == -1 or until > now)


def schedule_zone(c):
    return ZoneInfo(c['location']['timezone']) if c.get('mode') == 'solar' else None


def dated_schedule(c, date):
    """Actual timestamps, including offsets crossing midnight and local DST."""
    tz = schedule_zone(c)
    def manual(key):
        hour, minute = map(int, c[key].split(':'))
        return dt.datetime.combine(date, dt.time(hour, minute), tzinfo=tz).timestamp()
    if c.get('mode') != 'solar':
        return dict(sunrise=manual('morning'), sunset=manual('evening'), fallback=False)
    raw = solar.day(STATE, c['location'], date)
    if None in raw.values():
        return dict(sunrise=manual('morning'), sunset=manual('evening'), fallback=True)
    return dict(sunrise=raw['sunrise'] + c['sunrise_offset'] * 60,
                sunset=raw['sunset'] + c['sunset_offset'] * 60, fallback=False,
                raw_sunrise=raw['sunrise'], raw_sunset=raw['sunset'])


def schedule_events(c, now):
    date = dt.datetime.fromtimestamp(now, schedule_zone(c)).date()
    events = []
    for offset in range(-2, 3):
        schedule = dated_schedule(c, date + dt.timedelta(days=offset))
        events.extend((schedule[key], key) for key in ('sunrise', 'sunset'))
    return sorted(events)


def schedule_temperature(c, now):
    if c.get('mode') != 'solar':
        local = dt.datetime.fromtimestamp(now)
        return temperature(c, local.hour * 60 + local.minute + local.second / 60)
    events = schedule_events(c, now)
    previous = max(event for event in events if event[0] <= now)
    following = min(event for event in events if event[0] > now)
    span = min(c['transition'] * 60, following[0] - previous[0])
    progress = min(1., (now - previous[0]) / max(1., span))
    eased = progress * progress * (3 - 2 * progress)
    start, end = (c['night'], c['day']) if previous[1] == 'sunrise' else (c['day'], c['night'])
    return start + (end - start) * eased


def phase(c, now):
    """Where the schedule stands: day, sunset (getting warmer), night or sunrise."""
    goal = schedule_temperature(c, now)
    if goal >= c['day'] - 1:
        return 'day'
    if goal <= c['night'] + 1:
        return 'night'
    return 'sunset' if schedule_temperature(c, now + 60) < goal else 'sunrise'


def target(c, pause, now):
    return 6500 if paused(pause, now) else schedule_temperature(c, now)


def solar_settings(c):
    """Validate a user change across two complete years before committing it."""
    c = validate(c)
    if c['mode'] == 'solar':
        year = dt.datetime.now(schedule_zone(c)).year
        solar.prepare(STATE, c['location'], year)
        solar.check_offsets(STATE, c['location'], year, c['sunrise_offset'], c['sunset_offset'])
    return c


def offset_text(value):
    if not value:
        return 'No offset'
    return f'{abs(value)} min ' + ('later' if value > 0 else 'earlier')


def ramp(current, goal, elapsed, rate=150):
    # Cap elapsed time after suspend. The daily schedule itself is much slower.
    delta = rate * min(max(elapsed, 0), 1)
    return current + max(-delta, min(delta, goal - current))


def ipc(*args):
    result = subprocess.run(['hyprctl', 'hyprsunset', *map(str, args)], capture_output=True, text=True, timeout=3)
    if result.returncode or any(x in result.stdout.lower() for x in ('error', "couldn't", 'unknown', 'invalid')):
        raise RuntimeError((result.stderr or result.stdout).strip() or 'Cannot reach the color service.')
    return result.stdout.strip()


def snapshot():
    state = read_json(STATE / 'status.json', {})
    if time.time() - state.get('updated', 0) > 12:
        return state | dict(error='Sunshift is not running.')
    return state


def next_evening(now, config=None):
    """Next start of the user's warm transition, in the system's local timezone."""
    c = load_config() if config is None else config
    if c.get('mode') == 'solar':
        return min(stamp for stamp, kind in schedule_events(c, now) if kind == 'sunset' and stamp > now)
    hour, minute = map(int, c['evening'].split(':'))
    today = dt.datetime.fromtimestamp(now).date()
    for offset in (0, 1, 2):
        when = dt.datetime.combine(today + dt.timedelta(days=offset), dt.time(hour, minute)).timestamp()
        if when > now:
            return when
    raise ValueError('Could not determine the next evening transition.')


def tomorrow_evening(now, config=None):
    """Start of the warm transition on the next calendar day, not just the next one."""
    tomorrow = dt.datetime.combine(dt.datetime.fromtimestamp(now).date() + dt.timedelta(days=1), dt.time())
    return next_evening(tomorrow.timestamp(), config)


def read_pause():
    state = read_json(STATE / 'pause.json', {})
    if state.get('mode') == 'evening':
        state['until'] = next_evening(state['started'])
    elif state.get('mode') == 'tomorrow':
        state['until'] = tomorrow_evening(state['started'])
    return state


def pause_action(action, duration=60):
    STATE.mkdir(parents=True, exist_ok=True)
    # Serialize panel and shortcut changes so rapid extensions are not lost.
    with (STATE / 'pause.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = read_pause()
        now = time.time()
        active = paused(current, now)
        if action == 'resume' or (action == 'toggle' and active):
            until = 0
        elif action == 'extend':
            if not active or current.get('until', 0) == -1:
                raise ValueError('Start a timed pause before extending it.')
            if duration <= 0:
                raise ValueError('Extension must be positive.')
            until = current['until'] + duration * 60
        elif action == 'evening':
            until = next_evening(now)
        elif action == 'tomorrow':
            until = tomorrow_evening(now)
        else:
            until = -1 if duration == 0 else now + duration * 60
        state = {'until': until}
        if action in ('evening', 'tomorrow'):
            state.update(mode=action, started=now)
        atomic_json(STATE / 'pause.json', state)


def remaining_text(until, now):
    if until == -1:
        return 'Until you resume'
    seconds = max(0, math.ceil(until - now))
    hours, seconds = divmod(seconds, 3600)
    minutes, seconds = divmod(seconds, 60)
    return f'{hours:02}:{minutes:02}:{seconds:02}'


def daemon():
    STATE.mkdir(parents=True, exist_ok=True)
    lock = (STATE / 'daemon.lock').open('w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    running = True

    def stop(*_):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    current, previous, last_sent, neutral = 6500., time.monotonic(), 0, False
    was_paused, quick_transition = False, False
    locator, locate_due = None, 0.
    try:
        response = ipc('temperature')
        if response.isdigit():
            current = float(response)
    except (RuntimeError, OSError, subprocess.TimeoutExpired):
        pass
    try:
        while running:
            now = time.time()
            try:
                c = load_config()
                if locator and locator.poll() is not None:
                    locate_due = now + (RELOCATE_EVERY if locator.returncode == 0 else RELOCATE_RETRY)
                    locator = None
                if c['auto_locate'] and not locator and now >= locate_due:
                    # Network lookups run in their own process so the colour ramp never waits.
                    locator = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), 'relocate'],
                                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                elif not c['auto_locate']:
                    locate_due = 0.
                pause = read_pause()
                is_paused = paused(pause, now)
                if is_paused != was_paused:
                    quick_transition = True
                was_paused = is_paused
                goal = target(c, pause, now)
                tick = time.monotonic()
                next_value = ramp(current, goal, tick - previous, 350 if quick_transition else 150)
                previous = tick
                value = round(next_value)
                # Reassert every 10 seconds, including after monitor reconnects.
                if value != round(current) or now - last_sent >= 10 or neutral != (value == 6500):
                    ipc('temperature', value)
                    if value == 6500:
                        ipc('identity')
                    last_sent, neutral = now, value == 6500
                current = next_value
                if current == goal:
                    quick_transition = False
                status = dict(temperature=value, target=round(goal), paused=paused(pause, now), until=pause.get('until', 0), phase=phase(c, now), error=None)
            except (ValueError, TypeError, OSError, RuntimeError, subprocess.TimeoutExpired) as error:
                status = dict(error=str(error))
            atomic_json(STATE / 'status.json', status | dict(updated=now))
            time.sleep(.1 if quick_transition else 1)
    finally:
        try:
            ipc('identity')
        except (RuntimeError, OSError, subprocess.TimeoutExpired):
            pass
        atomic_json(STATE / 'status.json', dict(updated=0, error='Sunshift has stopped.'))


def until_clock(until):
    """'18:34' today, 'tomorrow 18:34', or 'Tue 18:34' further ahead."""
    when = dt.datetime.fromtimestamp(until)
    days = (when.date() - dt.date.today()).days
    return when.strftime('%H:%M') if days <= 0 else ('tomorrow ' if days == 1 else when.strftime('%a ')) + when.strftime('%H:%M')


def status_text(s):
    if s.get('error'):
        return s['error']
    if s.get('paused'):
        until = s.get('until', -1)
        return 'Paused · until you resume' if until == -1 else 'Paused · until ' + until_clock(until)
    return 'Automatic · following your schedule'


def panel_data():
    """Everything the Omarchy bar panel shows, in one JSON object."""
    now = time.time()
    s = snapshot()
    try:
        c, config_error = load_config(), None
    except (ValueError, TypeError) as error:
        c, config_error = DEFAULT.copy(), str(error)
    pause = read_pause()
    active = paused(pause, now)
    until = pause.get('until', 0) if active else 0
    tz = schedule_zone(c)
    date = dt.datetime.fromtimestamp(now, tz).date()

    def hm(stamp):
        return dt.datetime.fromtimestamp(stamp, tz).strftime('%H:%M')

    effective = dated_schedule(c, date)
    midnight = dt.datetime.combine(date, dt.time(), tzinfo=tz)
    curve = [round(schedule_temperature(c, (midnight + dt.timedelta(minutes=15 * step)).timestamp())) for step in range(97)]
    sun = None
    if c['location']:
        location_tz = ZoneInfo(c['location']['timezone'])
        local_date = dt.datetime.now(location_tz).date()
        solar.prepare(STATE, c['location'], local_date.year)
        raw = solar.day(STATE, c['location'], local_date)
        sun = {key: dt.datetime.fromtimestamp(raw[key], location_tz).strftime('%H:%M') if raw[key] is not None else None
               for key in ('sunrise', 'sunset')}
    try:
        evening_next = next_evening(now, c)
        sunset_next = hm(evening_next)
        sunset_tomorrow = hm(tomorrow_evening(now, c))
        next_is_today = dt.datetime.fromtimestamp(evening_next).date() == dt.datetime.fromtimestamp(now).date()
    except ValueError:
        sunset_next, sunset_tomorrow, next_is_today = None, None, False
    return dict(
        error=s.get('error') or config_error,
        temperature=s.get('temperature'),
        target=s.get('target'),
        paused=active,
        until=until,
        until_text=('' if not active else 'until you resume' if until == -1 else 'until ' + until_clock(until)),
        remaining=(0 if not active else -1 if until == -1 else max(0, math.ceil(until - now))),
        status=status_text(s | dict(paused=active, until=until)),
        config=c,
        schedule=dict(morning=hm(effective['sunrise']), evening=hm(effective['sunset']), fallback=effective['fallback']),
        sun=sun,
        suggestion=None if c['location'] else solar.timezone_suggestion(),
        located=read_json(STATE / 'locate.json', {}),
        curve=curve,
        now_minute=round((now - midnight.timestamp()) / 60, 1),
        phase=phase(c, now),
        next_sunset=sunset_next,
        next_sunset_today=next_is_today,
        tomorrow_sunset=sunset_tomorrow,
    )


def set_config(changes):
    """Merge validated changes into the saved schedule."""
    if not isinstance(changes, dict) or not changes or not set(changes) <= set(DEFAULT):
        raise ValueError('Unknown setting.')
    current = load_config()
    if 'location' in changes and 'auto_locate' not in changes:
        # A chosen city wins over Wi-Fi location, which would overwrite it later.
        changes = changes | dict(auto_locate=False)
    if changes.get('auto_locate') is True and not current['auto_locate']:
        changes = changes | dict(location=wifi_location(), mode='solar')
    c = solar_settings(current | changes)
    atomic_json(CONFIG / 'config.json', c)
    return c


def wifi_location():
    """Look the place up via Wi-Fi and note when, so the panel can say so."""
    try:
        location = solar.locate_wifi()
    except ValueError as error:
        atomic_json(STATE / 'locate.json', dict(time=time.time(), error=str(error)))
        raise
    atomic_json(STATE / 'locate.json', dict(time=time.time(), error=None))
    return location


def relocate():
    """Background refresh while Wi-Fi location is on; exits non-zero so the daemon retries sooner."""
    try:
        if not load_config()['auto_locate']:
            return
        location = wifi_location()
        c = load_config()
        if c['auto_locate'] and c['location'] != location:
            atomic_json(CONFIG / 'config.json', solar_settings(c | dict(location=location)))
    except (ValueError, TypeError, OSError):
        raise SystemExit(1)


def answer(work):
    """Panel commands always print JSON, so the bar can show the message."""
    try:
        print(json.dumps(dict(ok=True) | work(), ensure_ascii=False))
    except (ValueError, TypeError, OSError) as error:
        print(json.dumps(dict(ok=False, error=str(error)), ensure_ascii=False))


def open_panel():
    """Open the Sunshift panel in the Omarchy bar."""
    raise SystemExit(subprocess.run(['omarchy-shell', 'sunshift', 'open']).returncode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', nargs='?', default='open', choices=['open', 'daemon', 'status', 'pause', 'resume', 'toggle', 'extend', 'evening', 'tomorrow', 'panel', 'set', 'locate', 'relocate'])
    parser.add_argument('value', nargs='?', help='set: JSON object of settings · locate: city or postal code')
    parser.add_argument('--minutes', type=int, default=60, help='0 = until you resume')
    args = parser.parse_args()
    if args.minutes < 0:
        parser.error('--minutes must be at least 0')
    if args.command == 'panel':
        answer(panel_data)
    elif args.command == 'set':
        answer(lambda: dict(config=set_config(json.loads(args.value or 'null'))))
    elif args.command == 'locate':
        answer(lambda: dict(results=solar.search_locations(args.value or '', STATE)))
    elif args.command in ('pause', 'resume', 'toggle', 'extend', 'evening', 'tomorrow'):
        pause_action(args.command, args.minutes)
    elif args.command == 'status':
        print(json.dumps(snapshot(), indent=2, ensure_ascii=False))
    else:
        {'open': open_panel, 'daemon': daemon, 'relocate': relocate}[args.command]()


if __name__ == '__main__':
    main()
