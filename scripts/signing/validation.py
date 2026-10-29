"""Pure checks shared by signing preflight and synthetic tests."""
import datetime as dt
import fnmatch
import re
import uuid

APP = 'dev.lunchbox-labs.carplay-compass'
ACTIVITY = APP + '.activity'


class SigningError(ValueError):
    """Safe, credential-free diagnostic."""


def require(condition, message):
    if not condition:
        raise SigningError(message)


def validate_build(build):
    require(re.fullmatch(r'[1-9][0-9]{0,3}\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)', build),
            'Choose a build number n.n.n (first 1–9999, others 0–99, no leading zeroes).')


def validate_profile(profile, team, bundle, certificate):
    require(profile.get('TeamIdentifier') == [team], 'Profile team mismatch.')
    expiry = profile['ExpirationDate'].replace(tzinfo=dt.timezone.utc)
    require(expiry > dt.datetime.now(dt.timezone.utc), 'Profile expired; regenerate it.')
    uuid.UUID(profile['UUID'])
    require(certificate in profile.get('DeveloperCertificates', []), 'Profile certificate mismatch.')
    require('ProvisionedDevices' not in profile and not profile.get('ProvisionsAllDevices'),
            'Use App Store Connect distribution profiles.')
    ent = profile['Entitlements']
    require(ent.get('application-identifier') == team + '.' + bundle, 'Profile app ID mismatch.')
    require(ent.get('com.apple.developer.team-identifier') == team, 'Entitlement team mismatch.')
    require(ent.get('get-task-allow') is False and ent.get('beta-reports-active') is True,
            'Profile is not an App Store Connect distribution profile.')
    if bundle == APP:
        require(ent.get('com.apple.developer.carplay-driving-task') is True,
                'Regenerate the main profile after Driving Task approval.')


def permitted(value, allowance):
    if isinstance(value, list) and isinstance(allowance, list):
        return all(any(permitted(v, a) for a in allowance) for v in value)
    if isinstance(value, str) and isinstance(allowance, str):
        return fnmatch.fnmatchcase(value, allowance)
    return type(value) is type(allowance) and value == allowance


def validate_product(info, ent, profile, bundle, build):
    require(info.get('CFBundleIdentifier') == bundle, 'Signed bundle ID mismatch.')
    require(info.get('CFBundleVersion') == build, 'Signed build number mismatch.')
    allowed = profile['Entitlements']
    require(ent.get('application-identifier') == allowed['application-identifier'], 'Signed app ID mismatch.')
    require(ent.get('com.apple.developer.team-identifier') == allowed['com.apple.developer.team-identifier'],
            'Signed team mismatch.')
    require(ent.get('get-task-allow') is False, 'Signed product allows debugging.')
    require(all(k in allowed and permitted(v, allowed[k]) for k, v in ent.items()),
            'Signed entitlements exceed the profile.')
    if bundle == APP:
        require(ent.get('com.apple.developer.carplay-driving-task') is True, 'Driving Task missing.')
