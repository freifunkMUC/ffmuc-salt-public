/*
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

var config = {
  // list images on console that match no model
  listMissingImages: false,
  // see devices.js for different vendor model maps
  vendormodels: vendormodels,
  // set enabled categories of devices (see devices.js)
  enabled_device_categories: ["recommended", "6_usable", "ath10k_lowmem", "small_kernel_part", "legacy_target", "4_32", "8_32", "16_32"],
  // Display a checkbox that allows to display not recommended devices.
  // This only make sense if enabled_device_categories also contains not
  // recommended devices.
  recommended_toggle: true,
  // Optional link to an info page about no longer recommended devices
  recommended_info_link: "https://bitte-router-erneuern.ffmuc.net/",
  // community prefix of the firmware images
  community_prefix: 'gluon-ffmuc-',
  // firmware version regex
  //version_regex: '-([0-9]+.[0-9]+.[0-9]+([+-~exp][0-9]+)?)[.-]',
  version_regex: '-(v[0-9.]+((-next|-main)[0-9]*)?)-',
  // relative image paths and branch
  directories: {
    // See also
    // https://github.com/freifunkMUC/ffmuc-salt-public/blob/main/nginx/domains/firmware.ffmuc.net.conf

    // OpenWrt 21.02
    // '/gluon-v2021.1.x/experimental/factory/': 'experimental',
    // '/gluon-v2021.1.x/experimental/other/': 'experimental',
    // '/gluon-v2021.1.x/experimental/sysupgrade/': 'experimental',
    // '/gluon-v2021.1.x/testing/factory/': 'testing',
    // '/gluon-v2021.1.x/testing/other/': 'testing',
    // '/gluon-v2021.1.x/testing/sysupgrade/': 'testing',
    // '/gluon-v2021.1.x/stable/factory/': 'stable',
    // '/gluon-v2021.1.x/stable/other/': 'stable',
    // '/gluon-v2021.1.x/stable/sysupgrade/': 'stable',

    // OpenWrt 22.03
    // '/gluon-v2023.1.x_v2021.1.x/experimental/factory/': 'experimental',
    // '/gluon-v2023.1.x_v2021.1.x/experimental/other/': 'experimental',
    // '/gluon-v2023.1.x_v2021.1.x/experimental/sysupgrade/': 'experimental',
    // '/gluon-v2023.1.x_v2021.1.x/testing/factory/': 'testing',
    // '/gluon-v2023.1.x_v2021.1.x/testing/other/': 'testing',
    // '/gluon-v2023.1.x_v2021.1.x/testing/sysupgrade/': 'testing',
    // '/gluon-v2023.1.x_v2021.1.x/stable/factory/': 'stable',
    // '/gluon-v2023.1.x_v2021.1.x/stable/other/': 'stable',
    // '/gluon-v2023.1.x_v2021.1.x/stable/sysupgrade/': 'stable',

    // OpenWrt 23.05
    '/gluon-v2023.2.x_v2023.1.x/experimental/factory/': 'experimental',
    '/gluon-v2023.2.x_v2023.1.x/experimental/other/': 'experimental',
    '/gluon-v2023.2.x_v2023.1.x/experimental/sysupgrade/': 'experimental',
    '/gluon-v2023.2.x_v2023.1.x/testing/factory/': 'testing',
    '/gluon-v2023.2.x_v2023.1.x/testing/other/': 'testing',
    '/gluon-v2023.2.x_v2023.1.x/testing/sysupgrade/': 'testing',
    '/v2025.12.3/stable/factory/': 'stable',
    '/v2025.12.3/stable/other/': 'stable',
    '/v2025.12.3/stable/sysupgrade/': 'stable',

    // OpenWrt 24.10
    '/gluon-main/experimental/factory/': 'gluon-main',
    '/gluon-main/experimental/other/': 'gluon-main',
    '/gluon-main/experimental/sysupgrade/': 'gluon-main',

    // OpenWrt master
    '/gluon-next/experimental/factory/': 'gluon-next',
    '/gluon-next/experimental/other/': 'gluon-next',
    '/gluon-next/experimental/sysupgrade/': 'gluon-next',
  },
  // page title
  title: 'Firmware',
  // branch descriptions shown during selection
  branch_descriptions: {
    stable: 'Gut getestet, zuverlässig und stabil.',
    testing: 'Vorab-Tests neuer Stable-Kandidaten.',
    experimental: 'Ungetestet, erster Schritt zu einer neuen Firmware.',
    "gluon-main": '⚠️ Bleeding Edge Gluon => experimenteller als experimental',
    "gluon-next": '⛔ Bleeding Edge OpenWRT => experimenteller als gluon-main. Keinerlei Support!',
  },
  // recommended branch will be marked during selection
  recommended_branch: 'stable',
  // experimental branches (show a warning for these branches)
  experimental_branches: ['experimental', 'gluon-main', 'gluon-next'],
  // path to preview pictures directory
  preview_pictures: '/.gluon-firmware-selector/pictures/',
  // link to changelog
  changelog: 'https://github.com/freifunkMUC/site-ffm/releases',
  // links for instructions like flashing of certain devices (optional)
  // can be set for a whole model or individual revisions
  // overwrites default values from devices_info in devices.js
  devices_info: {
    "FriendlyElec": {
      "NanoPi R2S": "https://gist.github.com/awlx/71b7727536f8f8bfe0c0031403ae86bf"
    },
    "Ubiquiti": {
      "EdgeRouter X": "https://ffmuc.net/freifunkmuc/2025/11/07/edgerouter-deprecation/",
      "EdgeRouter X SFP": "https://ffmuc.net/freifunkmuc/2025/11/07/edgerouter-deprecation/"
    },
  }
};
