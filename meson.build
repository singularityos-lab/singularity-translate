project('singularity-translate', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-translate"', language: 'c')
subdir('po')

gtk_dep = dependency('gtk4', version: '>= 4.16')
gee_dep = dependency('gee-0.8')
json_dep = dependency('json-glib-1.0')
soup_dep = dependency('libsoup-3.0')
secret_dep = dependency('libsecret-1')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

core_sources = files(
  'src/backends.vala',
  'src/store.vala',
  'src/document.vala',
)

executable('singularity-translate',
  core_sources + files(
    'src/service_client.vala',
    'src/search.vala',
    'src/window.vala',
    'src/tools.vala',
    'src/translate_bus.vala',
    'src/app.vala',
  ),
  dependencies: [gtk_dep, gee_dep, json_dep, soup_dep, secret_dep, libsingularity_dep],
  install: true
)

install_data('data/dev.sinty.translate.desktop',
  install_dir: get_option('datadir') / 'applications'
)

install_data('data/dev.sinty.translate.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

install_data('data/dev.sinty.translate.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)

install_data('data/icons/dev.sinty.translate.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

backends_test = executable('backends-test',
  core_sources + files('tests/backends_test.vala'),
  dependencies: [dependency('gio-2.0'), gee_dep, json_dep, soup_dep, secret_dep],
)
test_schemas = custom_target('test-schemas',
  input: 'data/dev.sinty.translate.gschema.xml',
  output: 'gschemas.compiled',
  command: [find_program('glib-compile-schemas'), '--strict', '--targetdir=@OUTDIR@', meson.current_source_dir() / 'data'],
)
test('backends', backends_test, args: [meson.current_source_dir() / 'tests' / 'fixtures'], depends: test_schemas,
  env: ['GSETTINGS_SCHEMA_DIR=' + meson.current_build_dir(), 'GSETTINGS_BACKEND=memory'])

executable('singularity-translate-service',
  core_sources + files('src/service.vala'),
  dependencies: [dependency('gio-2.0'), gee_dep, json_dep, soup_dep, secret_dep],
  install: true
)

service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'data/dev.sinty.TranslateService.service.in',
  output: 'dev.sinty.TranslateService.service',
  configuration: service_conf,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

configure_file(
  input: 'data/dev.sinty.translate.service.in',
  output: 'dev.sinty.translate.service',
  configuration: service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

install_data('data/capabilities/dev.sinty.Translate1.ini', 'data/capabilities/dev.sinty.TranslateService.ini',
  install_dir: get_option('datadir') / 'singularity' / 'capabilities'
)

install_data('data/search-providers/dev.sinty.translate.ini',
  install_dir: get_option('datadir') / 'singularity' / 'search-providers'
)

install_data('data/files-actions/dev.sinty.translate.translate-file.ini',
  install_dir: get_option('datadir') / 'singularity' / 'files-actions'
)

shared_module('singularity-translate-widget',
  files('src/service_client.vala', 'widget/quick_widget.vala'),
  dependencies: [gtk_dep, gee_dep, libsingularity_dep],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'widgets'
)

install_data('widget/dev.sinty.translate.quick.widget',
  install_dir: get_option('datadir') / 'singularity' / 'widgets'
)

shared_module('translate-tile',
  files('src/service_client.vala', 'plugin/translate_tile.vala'),
  dependencies: [gtk_dep, libsingularity_dep, dependency('libpeas-2')],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'plugins' / 'translate-tile'
)

install_data('plugin/translate-tile.plugin',
  install_dir: get_option('libdir') / 'singularity' / 'plugins' / 'translate-tile'
)

install_data('data/share-targets/dev.sinty.translate.text.ini',
  install_dir: get_option('datadir') / 'singularity' / 'share-targets'
)
