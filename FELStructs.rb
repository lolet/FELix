#   FELStructs.rb
#   Copyright 2014 Bartosz Jankowski
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
require_relative 'FELConsts'

class AWUSBRequest < BinData::Record # size 32
  string   :magic,     :length => 4, :initial_value => "AWUC"
  uint32le :tag,       :initial_value => 0
  uint32le :len,       :initial_value => 16
  uint16le :reserved1, :initial_value => 0
  uint8    :reserved2, :initial_value => 0
  uint8    :cmd_len,   :value => 0xC
  uint8    :cmd,       :initial_value => AW_USB_WRITE
  uint8    :reserved3, :initial_value => 0
  uint32le :len2, :value => :len
  array    :reserved, :type => :uint8, :initial_length  => 10, :value => 0
end

class AWUSBResponse < BinData::Record # size 13
  string   :magic, :length => 4, :initial_value => "AWUS"
  uint32le :tag
  uint32le :residue
  uint8    :csw_status					# != 0, then fail
end

class AWFELStandardRequest < BinData::Record # size 16
  uint16le :cmd, :initial_value => AWCOMMAND[:FEL_R_VERIFY_DEVICE]
  uint16le :tag, :initial_value => 0
  array    :reserved, :type => :uint8, :initial_length  => 12, :value => 0
end

class AWFELFESTrasportRequest < BinData::Record # size 16
  uint16le :cmd, :value => AWCOMMAND[:FES_RW_TRANSMITE]
  uint16le :tag, :initial_value => 0
  uint32le :address
  uint32le :len
  uint8    :media_index, :initial_value => FES_INDEX[:dram]
  uint8    :direction, :initial_value => FES_TRANSMITE_FLAG[:download]
  array    :reserved, :type => :uint8, :initial_length  => 2, :value => 0
end

class AWFELStatusResponse < BinData::Record # size 8
  uint16le :mark
  uint16le :tag
  uint8    :state
  array    :reserved, :type => :uint8, :initial_length => 3
end

class AWFELVerifyDeviceResponse < BinData::Record # size 32
  string   :magic, :length => 8, :initial_value => "AWUSBFEX"
  uint32le :board
  uint32le :fw
  uint16le :mode
  uint8    :data_flag
  uint8    :data_length
  uint32le :data_start_address
  array    :reserved, :type => :uint8, :initial_length => 8
end

class AWFESVerifyStatusResponse < BinData::Record # size 12
  uint32le :flags # always 0x6a617603
  uint32le :fes_crc # always 0
  int32le  :last_error # 0 if OK, -1 if fail
end

class AWFELMessage < BinData::Record # size 16
  uint16le :cmd, :initial_value => AWCOMMAND[:FES_DOWNLOAD]
  uint16le :tag, :initial_value => 0
  uint32le :address # also msg_len, start for verify
  # addr + totalTransLen / 512 => FES_MEDIA_INDEX_PHYSICAL, FES_MEDIA_INDEX_LOG
  # addr + totalTransLen => FES_MEDIA_INDEX_DRAM
  # totalTransLen => 65536 (max chunk)
  uint32le :len
  uint32le :flags, :initial_value => FEX_TAGS[:none] # one or more of FEX_TAGS
end
