#!/usr/bin/env python3
import contextlib
import copy
import io
import json
import os
import runpy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
GENERATOR = runpy.run_path(str(TOOLS / 'generate-sdk-backend.py'))
CAPABILITY = 'SystemCapability.HiviewDFX.HiProfiler.HiDebug'
OTHER_CAPABILITY = 'SystemCapability.Test.Other'
OLD_TARGET = 'PerformanceAnalysisKit.hidebug.dumpJsHeapData'
RAW_TARGET = 'PerformanceAnalysisKit.hidebug.dumpJsRawHeapData'


def candidate(name='dumpJsHeapData', params=None, return_type='void', promise=False):
    return {
        'target': 'PerformanceAnalysisKit.hidebug.' + name,
        'module': 'hidebug',
        'name': name,
        'file': '@ohos.hidebug.d.ts',
        'params': [['filename', 'string', False]] if params is None else params,
        'returnType': return_type,
        'isPromise': promise,
        'deprecated': False,
    }


def declaration(name='dumpJsHeapData', params='filename: string', return_type='void',
                deprecated=False, capability=CAPABILITY):
    tags = ('@deprecated since 26\n' if deprecated else '')
    if capability:
        tags += '@syscap ' + capability + '\n'
    return f'/**\n{tags}*/\nfunction {name}({params}): {return_type};\n'


class DeprecationCheck(unittest.TestCase):
    def attach(self, selected, *declarations, namespace_capability=''):
        prefix = f'/** @syscap {namespace_capability} */\n' if namespace_capability else ''
        source = prefix + 'declare namespace hidebug {\n' + ''.join(declarations) + '}\n'
        stderr = io.StringIO()
        with patch.object(Path, 'is_file', return_value=True), \
                patch.object(Path, 'read_text', return_value=source), \
                contextlib.redirect_stderr(stderr):
            GENERATOR['attach_syscaps'](selected, Path('/sdk'))
        return stderr.getvalue()

    def test_stale_selected_deprecated_signature_is_removed(self):
        selected = [candidate()]
        diagnostic = self.attach(selected, declaration(deprecated=True))
        self.assertEqual(selected, [])
        self.assertIn(OLD_TARGET + ': skipped deprecated SDK signature; no adapter generated', diagnostic)
        self.assertEqual(GENERATOR['build_import_table'](selected), {})

    def test_live_overload_survives_without_deprecated_syscap_ambiguity(self):
        for deprecated_first in (True, False):
            with self.subTest(deprecated_first=deprecated_first):
                selected = [candidate()]
                overloads = [declaration(deprecated=True, capability=OTHER_CAPABILITY), declaration()]
                if not deprecated_first:
                    overloads.reverse()
                self.assertEqual(self.attach(selected, *overloads), '')
                self.assertEqual(selected[0]['syscaps'], [CAPABILITY])
                entry = GENERATOR['gen_entry'](selected[0], GENERATOR['build_import_table'](selected))
                self.assertIn('hidebug.dumpJsHeapData(filename)', entry)
                self.assertNotIn(OTHER_CAPABILITY, entry)

    def test_unrelated_live_overload_does_not_rescue_deprecated_signature(self):
        selected = [candidate()]
        self.attach(selected, declaration(deprecated=True), declaration(params='filename: number'))
        self.assertEqual(selected, [])

    def test_optional_live_overload_can_match(self):
        selected = [candidate()]
        self.attach(selected, declaration(deprecated=True),
                    declaration(params='filename: string, needClean?: boolean'))
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0]['syscaps'], [CAPABILITY])

    def test_required_live_argument_does_not_rescue_deprecated_signature(self):
        selected = [candidate()]
        self.attach(selected, declaration(deprecated=True),
                    declaration(params='filename: string, needClean: boolean'))
        self.assertEqual(selected, [])

    def test_missing_or_ambiguous_live_syscap_still_fails(self):
        for overloads in ((declaration(capability=''),),
                          (declaration(), declaration(capability=OTHER_CAPABILITY)),
                          (declaration(params='filename: number'),)):
            with self.subTest(overloads=overloads), self.assertRaisesRegex(
                    SystemExit, 'missing or ambiguous @syscap'):
                self.attach([candidate()], *overloads)

    def test_deprecated_signature_needs_no_syscap(self):
        selected = [candidate()]
        self.attach(selected, declaration(deprecated=True, capability=''))
        self.assertEqual(selected, [])

    def test_namespace_syscap_and_numeric_normalization_preserved(self):
        selected = [candidate(params=[['filename', 'int', False]])]
        self.attach(selected, declaration(params='filename: number', capability=''),
                    namespace_capability=CAPABILITY)
        self.assertEqual(selected[0]['syscaps'], [CAPABILITY])

    def test_raw_heap_adapter_semantics_unchanged(self):
        selected = [candidate(), candidate('dumpJsRawHeapData',
                    [['needGC', 'boolean', True]], 'string', True)]
        self.attach(selected, declaration(deprecated=True),
                    declaration('dumpJsRawHeapData', 'needGC?: boolean', 'Promise<string>'),
                    declaration('dumpJsRawHeapData', 'needGC: boolean, needClean: boolean', 'Promise<string>'))
        self.assertEqual([entry['target'] for entry in selected], [RAW_TARGET])
        entry = GENERATOR['gen_entry'](selected[0], GENERATOR['build_import_table'](selected))
        self.assertIn("paramBoolean(params, 'needGC', false)", entry)
        self.assertIn('let result: string = await hidebug.dumpJsRawHeapData(needGC)', entry)
        self.assertIn('return result.toString()', entry)
        self.assertNotIn(OLD_TARGET + "'", entry)

    def test_generated_result_types_are_explicit(self):
        for return_type in ('string', 'number', 'int', 'long', 'double', 'boolean', 'bigint'):
            for promise in (False, True):
                with self.subTest(return_type=return_type, promise=promise):
                    entry = candidate('readValue', [], return_type, promise)
                    entry['syscaps'] = [CAPABILITY]
                    generated = GENERATOR['gen_entry'](entry, GENERATOR['build_import_table']([entry]))
                    expected_type = 'number' if return_type in ('int', 'long', 'double') else return_type
                    awaited = 'await ' if promise else ''
                    self.assertIn(f'let result: {expected_type} = {awaited}hidebug.readValue()', generated)
                    self.assertNotIn('let result =', generated)

    def test_socket_result_types_match_selected_signatures(self):
        expected = {
            'getDeviceId': 'string',
            'getL2capPsm': 'number',
            'getMaxReceiveDataSize': 'number',
            'getMaxTransmitDataSize': 'number',
            'isConnected': 'boolean',
        }
        selected = json.loads((TOOLS / 'sdk-backend-selected.json').read_text())
        backend = (ROOT / 'entry/src/main/ets/vera/VeraSdkBackend.ets').read_text()
        for name, return_type in expected.items():
            with self.subTest(name=name):
                entry = next(item for item in selected if item['target'] == 'ConnectivityKit.socket.' + name)
                entry['syscaps'] = ['SystemCapability.Communication.Bluetooth.Core']
                generated = GENERATOR['gen_entry'](entry, GENERATOR['build_import_table']([entry]))
                self.assertIn(f'let result: {return_type} = socket.{name}(', generated)
                self.assertIn(f'let result: {return_type} = socket.{name}(', backend)

    def test_targeted_metadata(self):
        index = json.loads((ROOT / 'entry/src/main/resources/rawfile/sdk-index.json').read_text())
        old = [entry for entry in index if entry['module'] == 'hidebug' and entry['name'] == 'dumpJsHeapData']
        self.assertTrue(old)
        self.assertTrue(all(entry['deprecated'] for entry in old))
        selected = json.loads((TOOLS / 'sdk-backend-selected.json').read_text())
        self.assertNotIn(OLD_TARGET, [entry['target'] for entry in selected])
        raw = next(entry for entry in selected if entry['target'] == RAW_TARGET)
        self.assertEqual(raw['params'], [['needGC', 'boolean', True]])
        self.assertEqual((raw['returnType'], raw['isPromise']), ('string', True))
        original = copy.deepcopy(raw)
        self.attach([raw], declaration('dumpJsRawHeapData', 'needGC?: boolean', 'Promise<string>'))
        raw.pop('syscaps')
        self.assertEqual(raw, original)


class KitImportCheck(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.sdk = self.root / '26.0.0'
        self.api = self.sdk / 'ets/dynamic/api'
        self.kits = self.api.parent / 'kits'
        self.api.mkdir(parents=True)
        self.kits.mkdir()
        (self.sdk / 'ets/oh-uni-package.json').write_text(
            json.dumps({'apiVersion': 26, 'platformVersion': '26.0.0'}))
        self.kit('PerformanceAnalysisKit',
                 "import actualDebug from '@ohos.hidebug';\nexport { actualDebug as debugExport };\n")
        self.kit('ConnectivityKit',
                 "import connection from '@ohos.bluetooth.connection';\nexport { connection };\n")
        self.kit('NetworkKit',
                 "export { default as connection } from '@ohos.net.connection';\n")
        self.kit('CoreFileKit',
                 "import fileIo from '@ohos.file.fs';\nexport { fileIo };\n")
        self.kit('DataProtectionKit',
                 "import dlpPermission from '@ohos.dlpPermission';\nexport { dlpPermission };\n")
        self.kit('DataLossPreventionKit',
                 "/** @deprecated since 12 */\nimport dlpPermission from '@ohos.dlpPermission';\n"
                 "export { dlpPermission };\n")
        self.selected = self.root / 'selected.json'
        self.out = self.root / 'Backend.ets'

    def kit(self, name, source):
        (self.kits / f'@kit.{name}.d.ts').write_text(source)

    def exports(self):
        return GENERATOR['sdk_kit_exports'](self.api)

    def backend(self, imports, marked=True):
        marker = GENERATOR['MARKER'] + '\n' if marked else ''
        return (imports + '\nexport type SdkAdapter = (params: Map<string, string>) => Promise<string>\n'
                'function manual(): void { keepFile(); keepLocal(); keepValue }\n' +
                GENERATOR['HELPER_MARKER'] + '\n\n' + GENERATOR['HELPER_BLOCK'] + '\n\n'
                'const ADAPTERS = new Map<string, SdkAdapter>([\n' + marker + '])\n'
                'export function runSdkAdapter(): void {}\n')

    def run_generator(self, source, selected, entries_only=False):
        self.out.write_text(source)
        self.selected.write_text(json.dumps(selected))
        for entry in selected:
            (self.api / entry['file']).write_text(
                'declare namespace ' + entry['module'] + ' {\n' +
                declaration(entry['name'], ', '.join(name + ': ' + ptype
                            for name, ptype, _ in entry['params']),
                            ('Promise<' + entry['returnType'] + '>'
                             if entry['isPromise'] else entry['returnType'])) + '}\n')
        argv = ['generate-sdk-backend.py', '--selected', str(self.selected), '--out', str(self.out)]
        if entries_only:
            argv.append('--entries-only')
        with patch.dict(os.environ, {'OHOS_BASE_SDK_HOME': str(self.sdk)}), \
                patch('sys.argv', argv), contextlib.redirect_stdout(io.StringIO()):
            GENERATOR['main']()
        return self.out.read_text()

    def test_real_export_alias_not_module_or_filename(self):
        table, text = GENERATOR['resolve_imports'](
            [candidate()], "import hidebug from '@ohos.hidebug'\n", '', self.exports())
        self.assertEqual(table, {('hidebug', '@ohos.hidebug.d.ts'): 'hidebug'})
        self.assertEqual(text, "import { debugExport as hidebug } from '@kit.PerformanceAnalysisKit'\n")

    def test_grouped_multiline_named_aliases_and_unrelated_imports(self):
        source = ('import {\n  debugExport as oldDebug,\n} from "@kit.PerformanceAnalysisKit";\n'
                  "import { fileIo as keepFile } from '@kit.CoreFileKit'\n"
                  "import { run as keepLocal, VALUE as keepValue } from './manual'\n")
        table, rewritten = GENERATOR['resolve_imports'](
            [candidate()], source, 'keepFile(); keepLocal(); keepValue', self.exports())
        self.assertEqual(table[('hidebug', '@ohos.hidebug.d.ts')], 'oldDebug')
        self.assertIn("import { fileIo as keepFile } from '@kit.CoreFileKit'", rewritten)
        self.assertIn("import { run as keepLocal, VALUE as keepValue } from './manual'", rewritten)
        self.assertEqual(rewritten.count('debugExport as oldDebug'), 1)
        self.assertNotIn('@ohos.', rewritten)

    def connections(self):
        selected = []
        for kit, file in (('ConnectivityKit', '@ohos.bluetooth.connection.d.ts'),
                          ('NetworkKit', '@ohos.net.connection.d.ts')):
            entry = candidate('isConnected', [], 'boolean')
            entry.update(target=kit + '.connection.isConnected', module='connection', file=file)
            selected.append(entry)
        return selected

    def test_both_connection_kits_keep_old_local_aliases(self):
        selected = self.connections()
        source = ("import bluetoothConnection from '@ohos.bluetooth.connection'\n"
                  "import netConnection from '@ohos.net.connection'\n")
        table, rewritten = GENERATOR['resolve_imports'](selected, source, '', self.exports())
        self.assertEqual(table, GENERATOR['build_import_table'](selected))
        self.assertIn("import { connection as bluetoothConnection } from '@kit.ConnectivityKit'", rewritten)
        self.assertIn("import { connection as netConnection } from '@kit.NetworkKit'", rewritten)
        for entry in selected:
            entry['syscaps'] = [CAPABILITY]
            self.assertIn(entry['target'], GENERATOR['gen_entry'](entry, table))
            self.assertIn(table[(entry['module'], entry['file'])] + '.isConnected()',
                          GENERATOR['gen_entry'](entry, table))
        self.assertEqual(GENERATOR['resolve_imports'](list(reversed(selected)), rewritten, '', self.exports()),
                         (table, rewritten))

    def test_colliding_named_import_allocates_unique_deterministic_local(self):
        source = "import { run as hidebug, extra } from './manual'\n"
        table, rewritten = GENERATOR['resolve_imports']([candidate()], source, '', self.exports())
        self.assertEqual(table[('hidebug', '@ohos.hidebug.d.ts')], 'hidebug_2')
        self.assertIn('debugExport as hidebug_2', rewritten)
        self.assertIn(source.strip(), rewritten)
        self.assertEqual(GENERATOR['resolve_imports']([candidate()], rewritten, '', self.exports()),
                         (table, rewritten))

    def test_connection_alias_collision_with_unrelated_named_import(self):
        source = "import { run as bluetoothConnection } from './manual'\n"
        table, rewritten = GENERATOR['resolve_imports'](self.connections(), source, '', self.exports())
        self.assertEqual(table[('connection', '@ohos.bluetooth.connection.d.ts')], 'bluetoothConnection_2')
        self.assertEqual(table[('connection', '@ohos.net.connection.d.ts')], 'netConnection')
        self.assertIn('connection as bluetoothConnection_2', rewritten)
        self.assertIn('connection as netConnection', rewritten)

    def test_dlp_uses_live_kit_and_missing_or_ambiguous_exports_fail(self):
        identity = ('@ohos.dlpPermission', 'default')
        self.assertEqual(GENERATOR['kit_binding'](identity, self.exports()),
                         ('@kit.DataProtectionKit', 'dlpPermission'))
        self.kit('AnotherKit', "export { default as other } from '@ohos.dlpPermission';\n")
        with self.assertRaisesRegex(SystemExit, 'ambiguous non-deprecated SDK kit export'):
            GENERATOR['kit_binding'](identity, self.exports())
        (self.kits / '@kit.DataProtectionKit.d.ts').unlink()
        (self.kits / '@kit.AnotherKit.d.ts').unlink()
        with self.assertRaisesRegex(SystemExit, 'non-deprecated SDK kit export: none'):
            GENERATOR['kit_binding'](identity, self.exports())
        with self.assertRaisesRegex(SystemExit, 'missing or ambiguous'):
            GENERATOR['kit_binding'](('@ohos.unknown', 'default'), self.exports())

    def test_full_generation_with_and_without_marker_is_idempotent(self):
        imports = ("import hidebug from '@ohos.hidebug'\n"
                   "import fs from '@ohos.file.fs'\n"
                   "import { run as keepLocal, VALUE as keepValue } from './manual'\n")
        for marked in (False, True):
            with self.subTest(marked=marked):
                source = self.backend(imports, marked).replace('keepFile()', 'fs()')
                result = self.run_generator(source, [candidate()])
                self.assertIn("import { fileIo as fs } from '@kit.CoreFileKit'", result)
                self.assertIn("import { debugExport as hidebug } from '@kit.PerformanceAnalysisKit'", result)
                self.assertIn("['" + OLD_TARGET + "'", result)
                self.assertIn('hidebug.dumpJsHeapData(filename)', result)
                self.assertIn('keepLocal(); keepValue', result)
                self.assertNotIn('@ohos.', result)
                self.assertEqual(self.run_generator(result, [candidate()]), result)

    def test_manual_grouped_kit_bindings_survive_selection_changes(self):
        imports = ("import { debugExport as oldDebug } from '@kit.PerformanceAnalysisKit'\n"
                   "import { fileIo as keepFile } from '@kit.CoreFileKit'\n"
                   "import { run as keepLocal, VALUE as keepValue } from './manual'\n")
        manual = "  ['Manual.file.read', async (): Promise<string> => { keepFile(); return keepValue }],\n"
        source = self.backend(imports).replace(GENERATOR['MARKER'], manual + GENERATOR['MARKER'])
        result = self.run_generator(source, [candidate()])
        self.assertIn(manual, result)
        self.assertIn('oldDebug.dumpJsHeapData(filename)', result)
        dropped = self.run_generator(result, [])
        self.assertIn(manual, dropped)
        self.assertIn("import { fileIo as keepFile } from '@kit.CoreFileKit'", dropped)
        self.assertIn("import { run as keepLocal, VALUE as keepValue } from './manual'", dropped)
        self.assertNotIn('@kit.PerformanceAnalysisKit', dropped)
        self.assertEqual(self.run_generator(dropped, []), dropped)

    def test_missing_mapping_or_duplicate_local_fails_before_writing(self):
        source = self.backend("import hidebug from '@ohos.hidebug'\n")
        (self.kits / '@kit.PerformanceAnalysisKit.d.ts').unlink()
        for entries_only in (False, True):
            with self.subTest(entries_only=entries_only), self.assertRaisesRegex(
                    SystemExit, '@ohos.hidebug .*missing or ambiguous non-deprecated SDK kit export'):
                self.run_generator(source, [candidate()], entries_only=entries_only)
            self.assertEqual(self.out.read_text(), source)
        with self.assertRaisesRegex(SystemExit, 'duplicate import local: same'):
            GENERATOR['resolve_imports']([], "import { one as same, two as same } from './manual'\n",
                                         '', self.exports())

    def test_entries_only_semantic_named_binding_preserves_other_bytes(self):
        imports = ('import { debugExport as oldDebug } from "@kit.PerformanceAnalysisKit";\n'
                   "import { fileIo as keepFile } from '@kit.CoreFileKit'\n"
                   "import { run as keepLocal, VALUE as keepValue } from './manual'\n")
        source = self.backend(imports)
        result = self.run_generator(source, [candidate()], entries_only=True)
        boundary = GENERATOR['MARKER'] + '\n'
        self.assertEqual(source.split(boundary)[0], result.split(boundary)[0])
        self.assertEqual(source[source.index('\n])'):], result[result.index('\n])'):])
        self.assertIn('oldDebug.dumpJsHeapData(filename)', result)
        self.assertEqual(self.run_generator(result, [candidate()], entries_only=True), result)

    def test_entries_only_checks_both_connection_identities(self):
        source = self.backend("import { connection as radioLink } from '@kit.ConnectivityKit'\n"
                              "import { connection as networkLink } from '@kit.NetworkKit'\n")
        result = self.run_generator(source, self.connections(), entries_only=True)
        self.assertIn('radioLink.isConnected()', result)
        self.assertIn('networkLink.isConnected()', result)
        missing = source.replace("import { connection as networkLink } from '@kit.NetworkKit'\n", '')
        with self.assertRaisesRegex(SystemExit, 'existing binding for connection from @ohos.net.connection'):
            self.run_generator(missing, self.connections(), entries_only=True)
        self.assertEqual(self.out.read_text(), missing)

    def test_entries_only_missing_or_wrong_named_binding_does_not_write(self):
        for imports in ("import { debugExport as hidebug } from '@kit.WrongKit'\n",
                        "import { wrong as hidebug } from '@kit.PerformanceAnalysisKit'\n",
                        "import { run as hidebug } from './manual'\n"):
            with self.subTest(imports=imports):
                source = self.backend(imports)
                with self.assertRaisesRegex(SystemExit, 'existing binding for hidebug from @ohos.hidebug'):
                    self.run_generator(source, [candidate()], entries_only=True)
                self.assertEqual(self.out.read_text(), source)

    def test_entries_only_legacy_default_is_semantically_equivalent(self):
        source = self.backend('import legacyDebug from "@ohos.hidebug";\n')
        result = self.run_generator(source, [candidate()], entries_only=True)
        self.assertIn('legacyDebug.dumpJsHeapData(filename)', result)
        self.assertIn('import legacyDebug from "@ohos.hidebug";', result)


if __name__ == '__main__':
    unittest.main()
