"""Location sources (time zone, city search, Wi-Fi) and offline yearly solar calendars."""
import datetime as dt
from functools import lru_cache
import hashlib
import http.client
import json
import math
import os
import re
import socket
import subprocess
from pathlib import Path
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

sys.path.insert(0, str(Path(__file__).resolve().parent / 'vendor'))
from astral import Observer
from astral.sun import sunrise, sunset

VERSION = 'astral-3.2-v1'


def validate_location(value):
    if not isinstance(value, dict):
        raise ValueError('Choose a location first.')
    for key, lo, hi in [('latitude', -90, 90), ('longitude', -180, 180)]:
        if type(value.get(key)) not in (int, float) or not math.isfinite(value[key]) or not lo <= value[key] <= hi:
            raise ValueError('Invalid location coordinates.')
    try:
        ZoneInfo(value['timezone'])
    except (KeyError, TypeError, ValueError, ZoneInfoNotFoundError):
        raise ValueError('This location has no valid time zone.') from None
    name = value.get('name')
    if not isinstance(name, str) or not name.strip() or len(name) > 240:
        raise ValueError('Invalid location name.')
    return {k: value[k] for k in ('name', 'latitude', 'longitude', 'timezone')}


NOMINATIM_URL = 'https://nominatim.openstreetmap.org/search'
USER_AGENT = 'Sunshift/1.0 (Omarchy night light; desktop city search)'
SEARCH_CACHE_DAYS = 30


def _zone_rows():
    """(country, latitude, longitude, zone) for every row of zone.tab: one country per row."""
    rows = []
    try:
        lines = Path(ZONE_TABLES[0]).read_text().splitlines()
    except OSError:
        return rows
    for line in lines:
        fields = line.split('\t')
        if line.startswith('#') or len(fields) < 3:
            continue
        match = re.fullmatch(r'([+-]\d{4,6})([+-]\d{5,7})', fields[1])
        if match:
            rows.append((fields[0], _degrees(match[1], 2), _degrees(match[2], 3), fields[2]))
    return rows


def _km(lat1, lon1, lat2, lon2):
    rad = math.radians
    a = (math.sin(rad(lat2 - lat1) / 2) ** 2
         + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(rad(lon2 - lon1) / 2) ** 2)
    return 6371 * 2 * math.asin(math.sqrt(a))


def _same_clock(zones):
    """True if all zones show the same time all year (e.g. Europe/Zurich and Europe/Busingen)."""
    year = dt.date.today().year
    probes = [dt.datetime(year, 1, 15, 12), dt.datetime(year, 7, 15, 12)]
    return len({tuple(ZoneInfo(z).utcoffset(p) for p in probes) for z in zones}) == 1


def timezone_for(country, lat, lon):
    """Time zone of a place without asking the network: the country's only zone, else the
    zone of the nearest main city in that country (or anywhere, if the country is unknown)."""
    rows = _zone_rows()
    own = [r for r in rows if r[0] == (country or '').upper()]
    zones = [r[3] for r in own]
    if len(own) == 1:
        return own[0][3]
    if own and _same_clock(zones):
        return system_timezone() if system_timezone() in zones else zones[0]
    if own:
        # Several clocks in one country (USA, Canada, Russia, ...): only Open-Meteo knows the
        # borders. It gets the coordinates of this search result, nothing else.
        try:
            params = urllib.parse.urlencode(dict(latitude=round(lat, 2), longitude=round(lon, 2), timezone='auto', forecast_days=1))
            zone = _fetch_json('https://api.open-meteo.com/v1/forecast?' + params, 'Open-Meteo').get('timezone')
            ZoneInfo(zone)
            return zone
        except (OSError, ValueError, TypeError, AttributeError, urllib.error.URLError, ZoneInfoNotFoundError):
            pass
    candidates = own or rows
    if not candidates:
        return None
    return min(candidates, key=lambda r: _km(lat, lon, r[1], r[2]))[3]


def _fetch_json(url, what):
    request = urllib.request.Request(url, headers={'User-Agent': USER_AGENT})
    with OPENER.open(request, timeout=10) as response:
        payload = json.loads(response.read(512_000))
    if not isinstance(payload, (dict, list)):
        raise ValueError(f'{what} returned an invalid response.')
    return payload


def _open_meteo(name, country=None):
    params = dict(name=name, count=6, language='en', format='json')
    if country:
        params['countryCode'] = country
    payload = _fetch_json('https://geocoding-api.open-meteo.com/v1/search?' + urllib.parse.urlencode(params), 'Open-Meteo')
    results = payload.get('results', []) if isinstance(payload, dict) else []
    places = []
    for item in results if isinstance(results, list) else []:
        if not isinstance(item, dict):
            continue
        parts = list(dict.fromkeys(str(item[k]) for k in ('name', 'admin1', 'country') if item.get(k)))
        places.append(dict(name=', '.join(parts), latitude=item.get('latitude'), longitude=item.get('longitude'),
                           timezone=item.get('timezone'), country=str(item.get('country_code') or '').upper()))
    return places


def _nominatim(query, country=None):
    params = {'q': query, 'format': 'jsonv2', 'limit': 6, 'addressdetails': 1, 'accept-language': 'en'}
    if country:
        params['countrycodes'] = country.lower()
    payload = _fetch_json(NOMINATIM_URL + '?' + urllib.parse.urlencode(params), 'OpenStreetMap')
    places = []
    for item in payload if isinstance(payload, list) else []:
        try:
            lat, lon = float(item['lat']), float(item['lon'])
            cc = str(item.get('address', {}).get('country_code', '')).upper()
        except (KeyError, TypeError, ValueError, AttributeError):
            continue
        parts = [p.strip() for p in str(item.get('display_name', '')).split(',') if p.strip()]
        name = ', '.join(parts[:3] + parts[-1:]) if len(parts) > 4 else ', '.join(parts)
        places.append(dict(name=name, latitude=lat, longitude=lon, timezone=timezone_for(cc, lat, lon), country=cc))
    return places


def _cache(root, key, value=None):
    """Nominatim asks clients to cache results; same answer for 30 days, at most 100 searches."""
    if root is None:
        return None
    path = Path(root) / 'search-cache.json'
    try:
        cache = json.loads(path.read_text())
        cache = cache if isinstance(cache, dict) else {}
    except (OSError, ValueError):
        cache = {}
    now = dt.datetime.now().timestamp()
    if value is None:
        hit = cache.get(key)
        return hit[1] if isinstance(hit, list) and len(hit) == 2 and now - hit[0] < SEARCH_CACHE_DAYS * 86400 else None
    cache[key] = [now, value]
    for old in sorted(cache, key=lambda k: cache[k][0])[:-100]:
        del cache[old]
    _write(path, cache)
    return value


def search_locations(query, cache_root=None):
    """Search OpenStreetMap (knows every postal code and district) and Open-Meteo (city names)
    with the typed text only. Postal codes are looked up in this computer's country first."""
    query = ' '.join(query.split())
    if not 2 <= len(query) <= 160:
        raise ValueError('Enter a city, district or postal code (at least 2 characters).')
    cached = _cache(cache_root, query.lower())
    if cached is not None:
        return cached
    country = system_country()
    postal_only = all(any(c.isdigit() for c in w) for w in query.replace(',', ' ').split())
    found, failures = [], 0
    try:
        osm = _nominatim(query, country) if postal_only and country else []
        if not osm:
            if postal_only and country:
                time.sleep(1.1)  # Nominatim allows one request per second.
            osm = _nominatim(query)
        found += osm
    except (OSError, ValueError, urllib.error.URLError):
        failures += 1
    try:
        found += _open_meteo(query)
    except (OSError, ValueError, urllib.error.URLError):
        failures += 1
    if failures == 2:
        raise ValueError('Location search is unavailable. Check your connection and try again. Your saved location is unchanged.')
    # This computer's country first, then drop places within 3 km of one already listed.
    found.sort(key=lambda place: place['country'] != country)
    locations = []
    for place in found:
        try:
            location = validate_location(place)
        except ValueError:
            continue
        if all(_km(location['latitude'], location['longitude'], other['latitude'], other['longitude']) > 3 for other in locations):
            locations.append(location)
        if len(locations) == 6:
            break
    return _cache(cache_root, query.lower(), locations) if locations else locations


def _connect_ipv4_first(address, timeout=socket._GLOBAL_DEFAULT_TIMEOUT, source_address=None, **_):
    """Like socket.create_connection, but IPv4 first: on networks with broken IPv6 every
    request would otherwise wait for the IPv6 attempt to time out."""
    host, port = address
    infos = sorted(socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM), key=lambda info: info[0] != socket.AF_INET)
    error = OSError(f'Cannot resolve {host}')
    for family, kind, proto, _, addr in infos:
        sock = socket.socket(family, kind, proto)
        try:
            if timeout is not socket._GLOBAL_DEFAULT_TIMEOUT:
                sock.settimeout(timeout)
            if source_address:
                sock.bind(source_address)
            sock.connect(addr)
            return sock
        except OSError as failure:
            error = failure
            sock.close()
    raise error


class _HTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._create_connection = _connect_ipv4_first  # http.client sets this per instance


class _HTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(_HTTPSConnection, req, context=self._context)


OPENER = urllib.request.build_opener(_HTTPSHandler)


ZONE_TABLES = ('/usr/share/zoneinfo/zone.tab', '/usr/share/zoneinfo/zone1970.tab')
GEOLOCATE_URL = 'https://api.beacondb.net/v1/geolocate'


def system_timezone():
    """The IANA name of this computer's time zone, e.g. 'America/Chicago', or None."""
    name = os.environ.get('TZ', '').lstrip(':')
    if not name:
        try:
            name = os.readlink('/etc/localtime').split('zoneinfo/', 1)[1]
        except (OSError, IndexError):
            return None
    try:
        ZoneInfo(name)
    except (ValueError, ZoneInfoNotFoundError):
        return None
    return name


def _degrees(text, width):
    sign = -1 if text[0] == '-' else 1
    digits = text[1:]
    value = int(digits[:width]) + int(digits[width:width + 2]) / 60
    if len(digits) > width + 2:
        value += int(digits[width + 2:width + 4]) / 3600
    return sign * value


def system_country():
    """Two-letter country code of this computer's time zone (first one listed), or None."""
    zone = system_timezone()
    for table in ZONE_TABLES:
        try:
            for line in Path(table).read_text().splitlines():
                fields = line.split('\t')
                if not line.startswith('#') and len(fields) >= 3 and fields[2] == zone:
                    return fields[0].split(',')[0]
        except OSError:
            continue
    return None


def timezone_suggestion():
    """The main city of this computer's time zone, from the tz database on disk. No network."""
    zone = system_timezone()
    if not zone or '/' not in zone or zone.startswith('Etc/'):
        return None
    for table in ZONE_TABLES:
        try:
            lines = Path(table).read_text().splitlines()
        except OSError:
            continue
        for line in lines:
            fields = line.split('\t')
            if line.startswith('#') or len(fields) < 3 or fields[2] != zone:
                continue
            match = re.fullmatch(r'([+-]\d{4,6})([+-]\d{5,7})', fields[1])
            if not match:
                continue
            city = zone.rsplit('/', 1)[1].replace('_', ' ')
            return validate_location(dict(name=city, latitude=round(_degrees(match[1], 2), 2),
                                          longitude=round(_degrees(match[2], 3), 2), timezone=zone))
    return None


def nearby_wifi():
    """Access points NetworkManager already sees: hardware address and signal in dBm, no names."""
    try:
        listing = subprocess.run(['nmcli', '-t', '-e', 'yes', '-f', 'SSID,BSSID,SIGNAL', 'device', 'wifi', 'list'],
                                 capture_output=True, text=True, timeout=15, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        raise ValueError('Wi-Fi location needs NetworkManager (nmcli), which is not available.') from None
    points = {}
    for line in listing.splitlines():
        fields = re.split(r'(?<!\\):', line)
        if len(fields) != 3:
            continue
        ssid, bssid, signal = (f.replace('\\:', ':') for f in fields)
        # Networks named *_nomap have opted out of location services.
        if ssid.endswith('_nomap') or not re.fullmatch(r'(?:[0-9A-F]{2}:){5}[0-9A-F]{2}', bssid) or not signal.isdigit():
            continue
        points[bssid.lower()] = round(int(signal) / 2 - 100)
    return [dict(macAddress=mac, signalStrength=dbm) for mac, dbm in points.items()]


def locate_wifi():
    """Ask BeaconDB where the nearby access points are. Sends their hardware addresses
    and signal strengths, never network names; the answer is rounded to about 1 km."""
    zone = system_timezone()
    if not zone:
        raise ValueError('Set a time zone for this computer first.')
    points = nearby_wifi()
    if len(points) < 2:
        raise ValueError('Not enough Wi-Fi networks nearby to find this place. Search for your city instead.')
    body = json.dumps(dict(considerIp=False, wifiAccessPoints=points)).encode()
    request = urllib.request.Request(GEOLOCATE_URL, data=body, method='POST', headers={
        'Content-Type': 'application/json', 'User-Agent': 'Sunshift/1.0 (desktop night light)'})
    try:
        with OPENER.open(request, timeout=15) as response:
            payload = json.loads(response.read(64_000))
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise ValueError('BeaconDB does not know the Wi-Fi networks here yet. Search for your city instead.') from None
        raise ValueError('Wi-Fi location is unavailable right now. Your saved location is unchanged.') from None
    except (OSError, ValueError, urllib.error.URLError):
        raise ValueError('Wi-Fi location is unavailable right now. Your saved location is unchanged.') from None
    try:
        lat, lng = float(payload['location']['lat']), float(payload['location']['lng'])
    except (KeyError, TypeError, ValueError):
        raise ValueError('Wi-Fi location returned an invalid answer. Your saved location is unchanged.') from None
    return validate_location(dict(name=_wifi_name(lat, lng), latitude=round(lat, 2),
                                  longitude=round(lng, 2), timezone=zone))


def _wifi_name(lat, lng):
    """'Near Vienna · Wi-Fi' when the time zone's main city is close, else plain coordinates."""
    city = timezone_suggestion()
    if city:
        if _km(lat, lng, city['latitude'], city['longitude']) <= 60:
            return f"Near {city['name']} · Wi-Fi"
    return f'Wi-Fi location · {lat:.2f}, {lng:.2f}'


def location_key(location):
    return json.dumps(validate_location(location), sort_keys=True)


def _write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, filename = tempfile.mkstemp(dir=path.parent, prefix='.calendar-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, separators=(',', ':'))
            stream.write('\n')
        os.replace(filename, path)
    finally:
        if os.path.exists(filename):
            os.unlink(filename)


def cache_path(root, location, year):
    digest = hashlib.sha256((VERSION + location_key(location)).encode()).hexdigest()[:20]
    return Path(root) / 'calendars' / digest / f'{year}.json'


def dates(year):
    day = dt.date(year, 1, 1)
    while day.year == year:
        yield day
        day += dt.timedelta(days=1)


def build_calendar(location, year):
    location = validate_location(location)
    observer = Observer(location['latitude'], location['longitude'])
    tz = ZoneInfo(location['timezone'])
    days = {}
    for date in dates(year):
        events = {}
        for name, calculate in [('sunrise', sunrise), ('sunset', sunset)]:
            try:
                events[name] = calculate(observer, date=date, tzinfo=tz).timestamp()
            except ValueError:
                # Polar day/night: preserve missing events explicitly, never invent times.
                events[name] = None
        days[date.isoformat()] = events
    return dict(version=VERSION, year=year, location=location, days=days)


def valid_calendar(value, location, year):
    if not isinstance(value, dict) or value.get('version') != VERSION or value.get('location') != location or value.get('year') != year:
        return False
    days = value.get('days')
    if not isinstance(days, dict) or set(days) != {d.isoformat() for d in dates(year)}:
        return False
    tz = ZoneInfo(location['timezone'])
    for day, events in days.items():
        if not isinstance(events, dict) or set(events) != {'sunrise', 'sunset'}:
            return False
        for stamp in events.values():
            if stamp is None:
                continue
            if type(stamp) not in (int, float) or not math.isfinite(stamp):
                return False
            try:
                if dt.datetime.fromtimestamp(stamp, tz).date().isoformat() != day:
                    return False
            except (ValueError, OverflowError, OSError):
                return False
    return True


@lru_cache(maxsize=24)
def _calendar(root, key, year):
    location = json.loads(key)
    path = cache_path(root, location, year)
    try:
        value = json.loads(path.read_text())
        if valid_calendar(value, location, year):
            return value
    except (OSError, ValueError):
        pass
    value = build_calendar(location, year)
    _write(path, value)
    return value


def calendar(root, location, year):
    return _calendar(str(root), location_key(location), year)


def day(root, location, date):
    return calendar(root, location, date.year)['days'][date.isoformat()]


def prepare(root, location, year):
    # Complete current and upcoming years are available immediately; later years
    # are generated locally on demand with the same saved location and offsets.
    for selected_year in (year, year + 1):
        calendar(root, location, selected_year)


def check_offsets(root, location, year, rise_offset, set_offset):
    for selected_year in (year, year + 1):
        for date in dates(selected_year):
            today = day(root, location, date)
            if None in today.values():
                continue
            morning = today['sunrise'] + rise_offset * 60
            evening = today['sunset'] + set_offset * 60
            tomorrow = day(root, location, date + dt.timedelta(days=1))['sunrise']
            if evening - morning < 300 or (tomorrow is not None and tomorrow + rise_offset * 60 - evening < 300):
                raise ValueError('These offsets would reverse sunrise and sunset on some days. Keep at least 5 minutes between them.')
