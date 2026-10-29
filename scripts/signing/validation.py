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


# Templates are the entire output vocabulary: never pass through an arbitrary
# error message, path, identifier, setting, or quoted value from a tool.
_BUILD_ERRORS = (
    "cannot find '[redacted]' in scope",
    "no such module '[redacted]'",
    "type '[redacted]' has no member '[redacted]'",
    "value of type '[redacted]' has no member '[redacted]'",
    "cannot convert value of type '[redacted]' to expected argument type '[redacted]'",
    "missing argument for parameter '[redacted]' in call",
    "Unable to open project '[redacted]'.",
    'The project named "[redacted]" does not contain a scheme named "[redacted]".',
    'Provisioning profile "[redacted]" doesn\'t include signing certificate "[redacted]".',
    'Provisioning profile "[redacted]" doesn\'t support the [redacted] capability.',
    'Provisioning profile "[redacted]" doesn\'t include the [redacted] entitlement.',
    'Provisioning profile "[redacted]" has expired.',
    "No profiles for '[redacted]' were found",
    'No signing certificate "[redacted]" found',
    'Signing for "[redacted]" requires a development team.',
    'None of the input catalogs contained a matching stickers icon set or app icon set named "[redacted]".',
    'Command CodeSign failed with a nonzero exit code',
    'Command SwiftCompile failed with a nonzero exit code',
    'Command SwiftEmitModule failed with a nonzero exit code',
    'Command CompileAssetCatalog failed with a nonzero exit code',
    'Command PhaseScriptExecution failed with a nonzero exit code',
    'linker command failed with exit code 1 (use -v to see invocation)',
)
_BUILD_PATTERNS = [(re.compile(re.escape(template).replace(re.escape('[redacted]'), r'''[^'"\r\n]+''')),
                    template) for template in _BUILD_ERRORS]
_FAILED_COMMAND = re.compile(
    r'\s+(SwiftCompile|SwiftEmitModule|CodeSign|CompileAssetCatalog|CompileAssetCatalogVariant|'
    r'ProcessInfoPlistFile|Ld|CompileC|PhaseScriptExecution|Copy|CopySwiftLibs)\s+.+')


def safe_build_diagnostics(*streams):
    """Return at most 20 fixed summaries (under 4 KiB), never raw log lines.

    Read complete lines only, capped at 8 KiB per input line. Unknown structures,
    non-ASCII/control characters and PEM blocks fail closed. Variable fields are
    discarded, even if they contain previously unknown or multiline secrets.
    """
    summaries = []
    for stream in streams:
        in_pem = False
        failed_commands = False
        # split only on LF: CR/ANSI/other controls must not create trusted lines.
        for raw in stream.split(b'\n'):
            if b'-----BEGIN ' in raw:
                in_pem = True
            if in_pem:
                if b'-----END ' in raw:
                    in_pem = False
                continue
            if len(raw) > 8192 or any(c < 32 and c != 9 or c > 126 for c in raw):
                continue
            line = raw.decode('ascii')
            if line == 'The following build commands failed:':
                failed_commands = True
                continue
            command = _FAILED_COMMAND.fullmatch(line) if failed_commands else None
            if command:
                summary = 'Failed build command: ' + command[1]
            else:
                failed_commands = False
                # Remove only recognized location and target wrappers. Their
                # arbitrary contents never reach the returned summary.
                match = re.fullmatch(
                    r'(?:(?:[^\r\n]+):([0-9]{1,6}):([0-9]{1,6}): |xcodebuild: )?'
                    r'error: (?:exportArchive )?(.+?)(?: \(in target \'[^\']+\' from project \'[^\']+\'\))?', line)
                if not match:
                    continue
                template = next((text for pattern, text in _BUILD_PATTERNS if pattern.fullmatch(match[3])), None)
                if template is None:
                    continue
                location = '[source]:' + match[1] + ':' + match[2] + ': ' if match[1] else ''
                summary = location + 'error: ' + template
            if summary not in summaries:
                summaries.append(summary)
            if len(summaries) == 20:
                return '\n'.join(summaries)
    return '\n'.join(summaries) or 'No recognized safe build diagnostics; unrecognized output withheld.'
