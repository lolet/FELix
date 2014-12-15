#!/usr/bin/env ruby
#   FELix.rb
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
require 'hex_string'
require 'hexdump'
require 'colorize'
require 'optparse'
require 'libusb'
require 'bindata'

require_relative 'FELStructs'
require_relative 'FELHelpers'

# @example Routines (Send command and read data)
#  1. Write (--> send | <-- recv)
#     --> AWUSBRequest(AW_USB_WRITE, len)
#     --> WRITE(len)
#     <-- READ(13) -> AWUSBResponse
#  (then)
#  2. Read
#     --> AWUSBRequest(AW_USB_READ, len)
#     <-- READ(len)
#     <-- READ(13) -> AWUSBResponse
#  (then)
#  3. Read status
#     --> AWUSBRequest(AW_USB_READ, 8)
#     <-- READ(8)
#     <-- READ(13) -> AWUSBResponse
#
# @example Some important info about memory layout. Treat ranges as [a..b-1]
#   0x0: SRAM_BASE
#   0x2000 - 0x6000: INIT_CODE (16384 bytes), also: DRAM_INIT_CODE_ADDR
#   0x7010 - 0x7D00: FEL_MEMORY (3312 bytes), also: FEL_RESERVE_START
#   => 0x7010 - 0x7210: SYS_PARA (512 bytes)
#   => 0x7210 - 0x7220: SYS_PARA_LOG_ADDR (16 bytes)
#   => 0x7220 - 0x7D00: SYS_INIT_PROC_ADDR (2784 bytes)
#   0x7D00 - 0x7E00: ? (256 bytes)
#   0x7E00 - ?     : DATA_START_ADDR
#   0x40000000: DRAM_BASE
#   => 0x40000000 - 0x40008000: FEX_SRAM_A_BASE (32768 bytes)
#   => 0x40008000 - 0x40028000: FEX_SRAM_B_BASE (131072 bytes)
#      => 0x40023C00: FEX_CRC32_VALID_ADDR (512 bytes)
#      => 0x40024000: FEX_SRAM_FES_IRQ_STACK_BASE (8192 bytes)
#      => 0x40023E00: FEX_SRAM_FES_PHO_PRIV_BASE (512 bytes)
#      => 0x40026000: FEX_SRAM_FET_STACK_BASE (8192 bytes)
#   => 0x40028000 - ?: FEX_SRAM_C_BASE
#      => 0x40100000: DRAM_TEST_ADDR, FEX_DRAM_BASE
#      => 0x40200000 - 0x40280000: FES_ADDR_CRYPTOGRAPH (fes.fex, max 524288 bytes)
#      => 0x40280000 - 0x40300000: FES_ADDR_PROCLAIM (524288 bytes)
#      => 0x40300000 - 0x40400000: FEX_MISC_RAM_BASE (5242880 bytes)
#      => 0x40400000 - 0x40410000: FET_PARA1_ADDR (65536 bytes)
#      => 0x40410000 - 0x40420000: FET_PARA2_ADDR (65536 bytes)
#      => 0x40420000 - 0x40430000: FET_PARA3_ADDR (65536 bytes)
#      => 0x40430000 - 0x40470000: FET_CODE_ADDR (262144 bytes), FED_CODE_DOWN_ADDR (524288 bytes)
#      => 0x40600000 - 0x40700000: BOOTX_BIN_ADDR (1048576 bytes)
#      => 0x40800000 - 0x40900000: FED_TEMP_BUFFER_ADDR (1048576 bytes)
#      => 0x40900000 - 0x40901000: FED_PARA_1_ADDR (4096 bytes)
#      => 0x40901000 - 0x40902000: FED_PARA_1_ADDR (4096 bytes)
#      => 0x40902000 - 0x40903000: FED_PARA_1_ADDR (4096 bytes)
#      (...)
#      => 0x4A000000: u-boot.fex
#      => 0x4D415244: SYS_PARA_LOG (second instance?)
#      => 0x5ffe7f08: MBR [not sure]
#      => 0x80600000: FEX_SRAM_FOR_FES_TEMP_BUF (65536 bytes)
# @example Booting to FES (boot 1.0)
#    1. Steps 1-4 of boot 2.0 method
#    2. FEL_DOWNLOAD: Send 512 bytes of data (seems its some failsafe DRAM config
#        AWSystemParameters) at 0x7010 (SYS_PARA)
#    3. FEL_DOWNLOAD: Send 2784 bytes of data (fes1-1.fex, padded with 0x00) at 0x7220 (SYS_INIT_PROC)
#    => 2784 because that's length of SYS_INIT_PROC
#    4. FEL_RUN: Run code at 0x7220 (fes1-1.fex)
#    5. FEL_UPLOAD: Get 16 bytes of data ("DRAM", rest 0x00) from 0x7210 (SYS_PARA_LOG)
#    6. FEL_DOWNLOAD: Send 16 bytes of data (filed 0x00) at 0x7210 (SYS_PARA_LOG)
#    => Clear SYS_PARA_LOG
#    7. FEL_DOWNLOAD: Send 8544 bytes of data (fes1-2.fex) at 0x2000 (INIT_CODE)
#    8. FEL_RUN: Run code at 0x2000 (fes1-2.fex) => inits and sets dram
#    9. FEL_UPLOAD: Get 16 bytes of data ("DRAM",0x00000001, rest 0x00) from 0x7210 (SYS_PARA_LOG)
#    => if 1 then DRAM is updated, else "Failed to update dram para"
#    10.FEL_UPLOAD: Get 512 bytes of data (AWSystemParameters) from 0x7010 (SYS_PARA)
#    11.FEL_DOWNLOAD: Send 8192 bytes of random generated data at 0x40100000 (DRAM_TEST_ADDR)
#    12.FEL_UPLOAD: Get 8192 bytes of data from 0x40100000 => verify if DRAM is working ok
#    13.FEL_DOWNLOAD: Send 16 bytes of data (filed 0x00) at 0x7210 (SYS_PARA_LOG)
#    => Clear SYS_PARA_LOG
#    13.FEL_DOWNLOAD: Send 86312 bytes of data (fes.fex) at 0x40200000 (FES_ADDR_CRYPTOGRAPH)
#    14.FEL_DOWNLOAD: Send 1964 bytes of data (fes_2.fex) at 0x7220 (SYS_INIT_PROC_ADDR)
#    15.FEL_RUN: Run code at 0x7220 (fes_2.fex)
#    => mode: fes, you can send FES commands now
#    *** Flash tool asks user if he would like to do format or upgrade
# @example Booting to FES (boot 2.0)
#    1. FEL_VERIFY_DEVICE => mode: fel, data_start_address: 0x7E00
#    2. FEL_VERIFY_DEVICE (not sure why it's spamming with this)
#    3. FEL_UPLOAD: Get 256 bytes of data (filed 0xCC) from 0x7E00 (data_start_address)
#    4. FEL_VERIFY_DEVICE
#    5. FEL_DOWNLOAD: Send 256 bytes of data (0x00000000, rest 0xCC) at 0x7E00 (data_start_address)
#    4. FEL_VERIFY_DEVICE
#    5. FEL_DOWNLOAD: Send 16 bytes of data (filed 0x00) at 0x7210 (SYS_PARA_LOG)
#    => It's performed to clean FES helper log
#    6. FEL_DOWNLOAD: Send 6496 bytes of data (fes1.fex) at 0x2000 (INIT_CODE)
#    7. FEL_RUN: Run code at 0x2000 (fes1.fex) => inits dram
#    8. FEL_UPLOAD: Get 136 bytes of data (DRAM...) from 0x7210 (SYS_PARA_LOG)
#    => After "DRAM" + 0x00000001, there's 32 dword with dram params
#    9. FEL_DOWNLOAD(12 times because u-boot.fex is 0xBC000 bytes):
#    => Send (u-boot.fex) 0x4A000000 in 65536 bytes chunks, last chunk is 49152
#    => bytes and ideally starts at config.fex data
#    => *** VERY IMPORTANT ***: There's set a flag (0x10) at 0xE0 byte of u-boot.
#    => Otherwise device will start normally after start of u-boot
#    10.FEL_RUN: Run code at 0x4A000000 (u-boot.fex; its called also fes2)
#    => mode: fes, you can send FES commands now
#    *** Flash tool asks user if he would like to do format or upgrade
# @example Flash process (A31s) (FES) (boot 2.0)
#    1. FEL_VERIFY_DEVICE: Allwinner A31s (sun6i), revision 0, FW: 1, mode: fes
#    2. FES_TRANSMITE (read flag, index:dram): Get 256 of data form 0x7e00 (filed 0xCC)
#    3. FEL_VERIFY_DEVICE: Allwinner A31s (sun6i), revision 0, FW: 1, mode: fes
#    These 3 steps above seems optional
#    4. FES_TRANSMITE: (write flag, index:dram): Send 256 of data at 0x7e00  (0x00000000, rest 0xCC)
#    5. FES_DOWNLOAD: Send 16 bytes @ 0x0, flags erase|finish (0x17f04) ((DWORD)0x01, rest 0x00)
#                     => Force sys_config.fex's erase_flag to 1
#    6. FES_VERIFY_STATUS: flags erase (0x7f04). Return  flags => 0x6a617603, crc => 0
#    7. FES_DOWNLOAD: write sunxi_mbr.fex, whole file at once => 16384 * 4 copies bytes size
#                     context: mbr|finish (0x17f01), inits NAND
#    8. FES_VERIFY_STATUS: flags mbr (0x7f01). Return flags => 0x6a617603, crc => 0
#    *** Flashing process starts
#    9. FES_FLASH_SET_ON: enable nand (actually it may intialize MMC I suppose),
#                         not needed if we've done step 8
#    10.FES_DOWNLOAD: write bootloader.fex (nanda) at 0x8000 in 65536 chunks, but address offset
#                     must be divided by 512 => 65536/512 = 128. Thus (0x8000, 0x8080, 0x8100, etc)
#                     at last chunk :finish context must be set
#    11.FES_VERIFY_VALUE: I'm pretty sure args are address and data size @todo
#                         Produces same as FES_VERIFY_STATUS => AWFESVerifyStatusResponse
#                         and CRC must be the same value as stored in Vbootloader.fex
#    12.FES_DOWNLOAD/FES_VERIFY_VALUE: write env.fex (nandb) at 0x10000 => because
#                                      previous partiton size was 0x8000 => see sys_partition.fex).
#    13.FES_DOWNLOAD/FES_VERIFY_VALUE: write boot.fex (nandc) at 0x18000
#    14.FES_DOWNLOAD/FES_VERIFY_VALUE: write system.fex (nandd) at 0x20000
#    15.FES_DOWNLOAD/FES_VERIFY_VALUE: write recovery.fex (nandg) at 0x5B8000
#    16.FES_FLASH_SET_OFF <= disable nand
#    17.FES_DOWNLOAD: Send u-boot.fex at 0x00, context is uboot (0x7f02)
#    18.FES_VERIFY_STATUS: flags uboot (0x7f04). Return flags => 0x6a617603, crc => 0
#    19.FES_QUERY_STORAGE: => returns 0 [4 bytes] @todo
#    20.FES_DOWNLOAD: Send boot0_nand.fex at 0x00, context is boot0 (0x7f03)
#    21.FES_VERIFY_STATUS: flags boot0 (0x7f03). Return flags => 0x6a617603, crc => 0
#    22.FES_SET_TOOL_MODE: Reboot device (8, 0) @todo
#    *** Weee! We've finished!
# @example Partition layout (can be easily recreated using sys_partition.fex or sunxi_mbr.fex)
#    => 1MB = 2048 in NAND addressing / 1 sector = 512 bytes
#     mbr        (sunxi_mbr.fex) @ 0 [16MB]
#     bootloader (nanda) @ 0x8000    [16MB]
#     env        (nandb) @ 0x10000   [16MB]
#     boot       (nandc) @ 0x18000   [16MB]
#     system     (nandd) @ 0x20000   [800MB]
#     data       (nande) @ 0x1B0000  [2048MB]
#     misc       (nandf) @ 0x5B0000  [16MB]
#     recovery   (nandg) @ 0x5B8000  [32MB]
#     cache      (nandh) @ 0x5C8000  [512MB]
#     databk     (nandi) @ 0x6C8000  [128MB]
#     userdisk   (nandj) @ 0x708000  [4096MB - 3584MB => 512MB for 4GB NAND]
# Main class for program. Contains methods to communicate with the device
class FELix
  # Open device, and setup endpoints
  # @param device [LIBUSB::Device] a device
  def initialize(device)
    raise "Unexcepted argument type: #{device.inspect}" unless device.
      kind_of?(LIBUSB::Device)
    @handle = device.open
    #@handle.detach_kernel_driver(0)
    @handle.claim_interface(0)
    @usb_out = device.endpoints.select { |e| e.direction == :out }[0]
    @usb_in = device.endpoints.select { |e| e.direction == :in }[0]
  end

  # Clean up on and finish program
  def bailout
    print "* Finishing"
    @handle.release_interface(0) if @handle
    @handle.close if @handle
    puts "\t[OK]".green
    exit
  rescue => e
    puts "\t[FAIL]".red
    puts "Error: #{e.message} at #{e.backtrace.join("\n")}"
  end

  # Send a request
  # @param data binary data
  # @return [AWUSBResponse] or nil if fails
  def send_request(data)
  # 1. Send AWUSBRequest to inform what we want to do (write/read/how many data)
    request = AWUSBRequest.new
    request.len = data.bytesize
    FELHelpers.debug_packet(request.to_binary_s, :write) if $options[:verbose]
    r = @handle.bulk_transfer(:dataOut => request.to_binary_s, :endpoint =>
     @usb_out)
    puts "Sent ".green << "#{r}".yellow << " bytes".green if $options[:verbose]
  # 2. Send a proper data
    FELHelpers.debug_packet(data, :write) if $options[:verbose]
    r2 = @handle.bulk_transfer(:dataOut => data, :endpoint => @usb_out)
    puts "Sent ".green << r2.to_s.yellow << " bytes".green if $options[:verbose]
  # 3. Get AWUSBResponse
  # Some request takes a lot of time (i.e. NAND format). Try to wait 60 seconds for response.
    r3 = @handle.bulk_transfer(:dataIn => 13, :endpoint => @usb_in, :timeout=>(60 * 1000))
    FELHelpers.debug_packet(r3, :read) if $options[:verbose]
    puts "Received ".green << "#{r3.bytesize}".yellow << " bytes".green if $options[:verbose]
    r3
  rescue => e
    raise e, "Failed to send ".red << "#{data.bytesize}".yellow << " bytes".red <<
    " (" << e.message << ")"
  end

  # Read data
  # @param len expected length of data
  # @return [String] binary data or nil if fail
  def recv_request(len)
  # 1. Send AWUSBRequest to inform what we want to do (write/read/how many data)
    request = AWUSBRequest.new
    request.len = len
    request.cmd = USBCmd[:read]
    FELHelpers.debug_packet(request.to_binary_s, :write) if $options[:verbose]
    r = @handle.bulk_transfer(:dataOut => request.to_binary_s, :endpoint => @usb_out)
    puts "Sent ".green << "#{r}".yellow << " bytes".green if $options[:verbose]
  # 2. Read data of length we specified in request
    recv_data = @handle.bulk_transfer(:dataIn => len, :endpoint => @usb_in)
    FELHelpers.debug_packet(recv_data, :read) if $options[:verbose]
  # 3. Get AWUSBResponse
    response = @handle.bulk_transfer(:dataIn => 13, :endpoint => @usb_in)
    puts "Received ".green << "#{response.bytesize}".yellow << " bytes".green if $options[:verbose]
    FELHelpers.debug_packet(response, :read) if $options[:verbose]
    recv_data
  rescue => e
    raise e, "Failed to receive ".red << "#{len}".yellow << " bytes".red <<
    " (" << e.message << ")"
  end

  # Get device status
  # @return [AWFELVerifyDeviceResponse] device status
  # @raise [String] error name
  def get_device_info
    data = send_request(AWFELStandardRequest.new.to_binary_s)
    if data == nil
      raise "Failed to send request (data: #{data})"
    end
    data = recv_request(32)
    if data == nil || data.bytesize != 32
      raise "Failed to receive device info (data: #{data})"
    end
    info = AWFELVerifyDeviceResponse.read(data)
    data = recv_request(8)
    if data == nil || data.bytesize != 8
      raise "Failed to receive device status (data: #{data})"
    end
    status = AWFELStatusResponse.read(data)
    raise "Command failed (Status #{status.state})" if status.state > 0
    info
  end

  # Read memory from device
  # @param address [Integer] memory address to read from
  # @param length [Integer] size of data
  # @param tags [Array<AWTags>] operation tag (zero or more of AWTags)
  # @param mode [AWDeviceMode] operation mode `:fel` or `:fes`
  # @return [String] requested data
  # @raise [String] error name
  def read(address, length, tags=[:none], mode=:fel)
    raise "Length not specifed" unless length
    raise "Address not specifed" unless address
    result = ""
    remain_len = length
    request = AWFELMessage.new
    request.cmd = FELCmd[:upload] if mode == :fel
    request.cmd = FESCmd[:upload] if mode == :fes

    while remain_len>0
      request.address = address
      if remain_len / FELIX_MAX_CHUNK == 0
        request.len = remain_len
      else
        request.len = FELIX_MAX_CHUNK
      end
      tags.each {|t| request.flags |= AWTags[t]}
      data = send_request(request.to_binary_s)
      raise "Failed to send request (response len: #{data.bytesize} !=" <<
        " 13)" if data.bytesize != 13

      output = recv_request(request.len)

      # Rescue if we received AWUSBResponse
      output = recv_request(request.len) if output.bytesize !=
       request.len && output.bytesize == 13
      # Rescue if we received AWFELStatusResponse
      output = recv_request(request.len) if output.bytesize !=
       request.len && output.bytesize == 8
      if output.bytesize != request.len
        raise "Data size mismatch (data len #{output.bytesize} != #{request.len})"
      end
      status = recv_request(8)
      raise "Failed to get device status (data: #{status})" if status.bytesize != 8
      fel_status = AWFELStatusResponse.read(status)
      raise "Command failed (Status #{fel_status.state})" if fel_status.state > 0
      result << output
      remain_len-=request.len
      # if EFEX_TAG_DRAM isnt set we read nand/sdcard
      if request.flags & AWTags[:dram] == 0 && mode == :fes
        next_sector=request.len / 512
        address+=( next_sector ? next_sector : 1) # Read next sector if its less than 512
      else
        address+=request.len
      end
      print "\r* #{$options[:mode]}: Reading data (" <<
      "#{length-remain_len}/#{$options[:length]} bytes)" unless $options[:verbose]
    end
    result
  end

  # Write data to device memory
  # @param address [Integer] place in memory to write
  # @param memory [String] data to write
  # @param tags [Array<AWTags>] operation tag (zero or more of AWTags)
  # @param mode [AWDeviceMode] operation mode `:fel` or `:fes`
  # @raise [String] error name
  def write(address, memory, tags=[:none], mode=:fel)
    raise "Memory not specifed" unless memory
    raise "Address not specifed" unless address
    total_len = memory.bytesize
    start = 0
    request = AWFELMessage.new
    request.cmd = FELCmd[:download] if mode == :fel
    request.cmd = FESCmd[:download] if mode == :fes

    while total_len>0
      request.address = address
      if total_len / FELIX_MAX_CHUNK == 0
        request.len = total_len
      else
        request.len = FELIX_MAX_CHUNK
      end
      tags.each {|t| request.flags |= AWTags[t]}
      data = send_request(request.to_binary_s)
      if data == nil
        raise "Failed to send request (#{request.cmd})"
      end
      data = send_request(memory.byteslice(start, request.len))
      if data == nil
        raise "Failed to send data (#{start}/#{memory.bytesize})"
      end
      data = recv_request(8)
      if data == nil || data.bytesize != 8
        raise "Failed to receive device status (data: #{data})"
      end
      status = AWFELStatusResponse.read(data)
      if status.state > 0
        raise "Command failed (Status #{status.state})"
      end
      start+=request.len
      total_len-=request.len
      # if EFEX_TAG_DRAM isnt set we write nand/sdcard
      if request.flags & AWTags[:dram] == 0 && mode == :fes
        next_sector=request.len / 512
        address+=( next_sector ? next_sector : 1) # Write next sector if its less than 512
      else
        address+=request.len
      end
      print "\r* #{$options[:mode]}: Writing data (" <<
      "#{start}/#{memory.bytesize} bytes)" unless $options[:verbose]
    end
  end

  # Execute code at specified memory
  # @param address [Integer] memory address to read from
  # @param mode [AWDeviceMode] operation mode `:fel` or `:fes`
  # @raise [String] error name
  def run(address, mode=:fel)
    request = AWFELMessage.new
    request.cmd = FELCmd[:run] if mode == :fel
    request.cmd = FESCmd[:run] if mode == :fes
    request.address = address
    data = send_request(request.to_binary_s)
    if data == nil
      raise "Failed to send request (#{request.cmd})"
    end
    data = recv_request(8)
    if data == nil || data.bytesize != 8
      raise "Failed to receive device status (data: #{data})"
    end
    status = AWFELStatusResponse.read(data)
    if status.state > 0
      raise "Command failed (Status #{status.state})"
    end
  end

  # Send raw request and try to read data
  # Test purposes only!
  # @param req [Integer] one of #FESCmd or #FELCmd
  # @raise [String] error name
  # @note Test purposes only!
  def request(req)
    request = AWFELMessage.new
    request.cmd = req
    request.len = 0
    data = send_request(request.to_binary_s)
    raise "Failed to send request (response len: #{data.bytesize} !=" <<
    " 13)" if data.bytesize != 13

    output = recv_request(FELIX_MAX_CHUNK)
    Hexdump.dump output

    status = recv_request(8)
    raise "Failed to get device status (data: #{status})" if status.bytesize != 8
    status = AWFELStatusResponse.read(status)
    raise "Command failed (Status #{status.state})" if fel_status.state > 0
  end

  # Erase NAND flash
  # @param mbr [String] new mbr. Must have 65536 bytes of length
  # @param format [TrueClass, FalseClass] erase data
  # @return [AWFESVerifyStatusResponse] result of sunxi_sprite_download_mbr (crc:-1 if fail)
  # @raise [String] error name
  # @note Use only in :fes mode
  def write_mbr(mbr, format=false)
    raise "No MBR provided" unless mbr
    mbr = File.read(mbr)
    raise "MBR is too small" unless mbr.bytesize == 65536
    # 1. Force platform->erase_flag => 1 or 0 if we dont wanna erase
    write(0, format ? "\1\0\0\0" : "\0\0\0\0", [:erase, :finish], :fes)
    # 2. Verify status (actually this is unecessary step [last_err is not set at all])
    # verify_status(:erase)
    # 3. Write MBR
    write(0, mbr, [:mbr, :finish], :fes)
    # 4. Get result value of sunxi_sprite_verify_mbr
    verify_status(:mbr)
  end

  # Verify last operation status
  # @param tags [Hash, Symbol] operation tag (zero or more of AWTags)
  # @return [AWFESVerifyStatusResponse] device status
  # @raise [String] error name
  # @note Use only in :fes mode
  def verify_status(tags=[:none])
    request = AWFELMessage.new
    request.cmd = FESCmd[:verify_status]
    request.address = 0
    request.len = 0
    if tags.kind_of?(Hash)
      tags.each {|t| request.flags |= AWTags[t]}
    else
      request.flags |= AWTags[tags]
    end
    data = send_request(request.to_binary_s)
    raise "Failed to send request (response len: #{data.bytesize} !=" <<
    " 13)" if data.length != 13
    data = recv_request(12)
    if data.bytesize == 0
      raise "Failed to receive verify request (no data)"
    elsif data.bytesize != 12
      raise "Failed to receive verify request (data len #{data.bytesize} != 12)"
    end
    status_response = AWFESVerifyStatusResponse.read(data)

    data = recv_request(8)
    if data == nil || data.bytesize != 8
      raise "Failed to receive device status (data: #{data})"
    end
    status = AWFELStatusResponse.read(data)
    if status.state > 0
      raise "Command failed (Status #{status.state})"
    end

    status_response
  end

  # Attach / Detach flash storage (handles `:flash_set_on` and `:flash_set_off`)
  # @param how [Symbol] desired state of flash (`:on` or `:off`)
  # @raise [String] error name
  # @note Use only in :fes mode. MBR must be written before
  def set_storage_state(how)
    raise "Invalid parameter state (#{how})" unless [:on, :off].include? how
    request = AWFELStandardRequest.new
    request.cmd = FESCmd[:flash_set_on] if how == :on
    request.cmd = FESCmd[:flash_set_off] if how == :off

    data = send_request(request.to_binary_s)
    raise "Failed to send request (response len: #{data.bytesize} !=" <<
      " 13)" if data.bytesize != 13

    data = recv_request(8)
    if data == nil || data.bytesize != 8
      raise "Failed to receive device status (data: #{data})"
    end
    status = AWFELStatusResponse.read(data)
    if status.state > 0
      raise "Command failed (Status #{status.state})"
    end

  end

  # Send FES_TRANSMITE request
  # Can be used to read/write memory in FES mode
  #
  # @param direction [Symbol] one of FESTransmiteFlag (`:write` or `:read`)
  # @param opts [Hash] Arguments
  # @option opts :address [Integer] place in memory to transmite
  # @option opts :memory [String] data to write (use only with `:write`)
  # @option opts :media_index [Symbol] one of FESIndex (default `:dram`)
  # @option opts :length [Integer] size of data (use only with `:read`)
  # @note Use only in :fes mode. Always prefer FES_DOWNLOAD/FES_UPLOAD instead of this
  def transmite(direction, *opts)
    opts = opts.first
    opts[:media_index] ||= :dram
    start = 0
    if direction == :write
      raise "Missing arguments for FES_TRANSMITE(download)" unless opts[:memory] &&
        opts[:address]

      total_len = opts[:memory].bytesize
      address = opts[:address]

      request = AWFESTrasportRequest.new # Little optimization
      request.direction = FESTransmiteFlag[direction]
      request.media_index = FESIndex[opts[:media_index]]

      while total_len>0
        request.address = address
        if total_len / FELIX_MAX_CHUNK == 0
          request.len = total_len
        else
          request.len = FELIX_MAX_CHUNK
        end
        data = send_request(request.to_binary_s)
        if data == nil
          raise "Failed to send request (#{request.cmd})"
        end
        data = send_request(opts[:memory].byteslice(start, request.len))
        if data == nil
          raise "Failed to send data (#{start}/#{opts[:memory].bytesize})"
        end
        data = recv_request(8)
        if data == nil || data.bytesize != 8
          raise "Failed to receive device status (data: #{data})"
        end
        status = AWFELStatusResponse.read(data)
        if status.state > 0
          raise "Command failed (Status #{status.state})"
        end
        start+=request.len
        total_len-=request.len
        next_sector=request.len / 512
        address+=( next_sector ? next_sector : 1) # Write next sector if its less than 512
        print "\r* #{$options[:mode]}: Writing data (" <<
        "#{start}/#{opts[:memory].bytesize} bytes)" unless $options[:verbose]
      end
    elsif direction == :read
      raise "Missing arguments for FES_TRANSMITE(upload)" unless opts[:length] &&
        opts[:address]
      # @todo Add support for reading>65536 data
      raise "reading more than #{FELIX_MAX_CHUNK} bytes is not implemented" <<
        " yet!" if opts[:length] > FELIX_MAX_CHUNK
      print "\r* Reading" unless $options[:verbose]

      request = AWFESTrasportRequest.new
      request.address = opts[:address]
      request.len = opts[:length]
      request.direction = FESTransmiteFlag[direction]
      request.media_index = FESIndex[opts[:media_index]]
      data = send_request(request.to_binary_s)
      raise "Failed to send AWFESTrasportRequest (response len: " <<
      "#{data.bytesize} != 13)" if data.bytesize != 13

      output = recv_request(request.len)

      # Rescue if we received AWUSBResponse
      output = recv_request(request.len) if output.bytesize !=
        request.len && output.bytesize == 13
      # Rescue if we received AWFELStatusResponse
      output = recv_request(request.len) if output.bytesize !=
        request.len && output.bytesize == 8

      raise "Data size mismatch (data len #{output.bytesize}" <<
      " != #{request.len})" if output.bytesize != request.len

      status = recv_request(8)
      raise "Failed to get device status (data: #{status})" if status.bytesize != 8
      fel_status = AWFELStatusResponse.read(status)
      raise "Command failed (Status #{fel_status.state})" if fel_status.state > 0
      output
    else
      raise "Unknown direction '(#{direction})'"
    end
  end

end

$options = {}
puts "FEL".red << "ix " << FELIX_VERSION << " by Lolet"
puts "Warning:".red << "I don't give any warranty on this software"
puts "You use it at own risk!"
puts "----------------------"

begin
  # ComputerInteger: hex strings (0x....) or decimal
  ComputerInteger = /(?:0x[\da-fA-F]+(?:_[\da-fA-F]+)*|\d+(?:_\d+)*)/
  Modes = [:fel, :fes]
  AddressCmds = [:write, :read, :run, :transmite]
  LengthCmds = [:read, :transmite]
  OptionParser.new do |opts|
      opts.banner = "Usage: FELix.rb action [options]"
      opts.separator "Actions:"

      opts.separator "* Common".light_blue.underline
      opts.on("--devices", "List the devices") do |v|
        devices = LIBUSB::Context.new.devices(:idVendor => 0x1f3a,
         :idProduct => 0xefe8)
        puts "No device found in FEL mode!" if devices.empty?
        i = 0
        devices.each do |d|
          puts "* %2d: (port %d) FEL device %d@%d %x:%x" % [++i, d.port_number,
            d.bus_number, d.device_address, d.idVendor, d.idProduct]
        end
        exit
      end
      opts.on("--decode path", String, "Decodes packets from Wireshark dump") do |f|
        FELHelpers.debug_packets(f)
        exit
      end
      opts.on("--version", "Show version") do
        puts FELIX_VERSION
        exit
      end

      opts.separator "* FEL/FES mode".light_blue.underline
      opts.on("--info", "Get device info") { $options[:action] = :device_info }
      opts.on("--run", "Execute code. Use with --address") do
        $options[:action] = :run
      end
      opts.on("--read file", String, "Read memory to file. Use with --address" <<
        " and --length. In FES mode you can additionally specify --tags") do |f|
         $options[:action] = :read
         $options[:file] = f
       end
      opts.on("--write file", String, "Write file to memory. Use with" <<
        " --address. In FES mode you can additionally specify --tags") do |f|
         $options[:action] = :write
         $options[:file] = f
      end
      opts.on("--request id", ComputerInteger, "Experimental ".red << "Send " <<
        "a standard request , then result response of #{FELIX_MAX_CHUNK} bytes") do |f|
         $options[:action] = :request
         $options[:request] = f[0..1] == "0x" ? Integer(f, 16) : f.to_i
      end

      opts.separator "* Only in FES mode".light_blue.underline
      opts.on("--format mbr", "Erase NAND Flash and write new MBR") do |f|
        $options[:action] = :format
        $options[:file] = f
      end
      opts.on("--mbr mbr", "Write new MBR") do |f|
        $options[:action] = :mbr
        $options[:file] = f
      end
      opts.on("--nand how", [:on, :off], "Enable/disable NAND driver. Use 'on'" <<
      " or 'off' as parameter)") do |b|
        $options[:action] = :storage
        $options[:how] = b
      end
      opts.on("--transmite file", "Read/write. May be used with --index" <<
        ", --address, --length. Omit --length if you want to write. Default" <<
        " index is :dram") do |f|
         $options[:action] = :transmite
         $options[:file] = f
      end

      opts.separator "\nOptions:"
      opts.on("-d", "--device number", Integer,
      "Select device number (default 0)") { |id| $options[:device] = id }

      opts.on("-a", "--address address", ComputerInteger, "Address (used for" <<
      " --" << AddressCmds.join(", --") << ")") do |a|
        $options[:address] = a[0..1] == "0x" ? Integer(a, 16) : a.to_i
      end
      opts.on("-l", "--length len", ComputerInteger, "Length of data (used " <<
      "for --" << LengthCmds.join(", --") << ")") do |l|
        $options[:length] = l[0..1] == "0x" ? Integer(l, 16) : l.to_i
      end
      opts.on("-m", "--mode mode", Modes, "Set command context to one of " <<
      "modes (" << Modes.join(", ") << ")") do |m|
        $options[:mode] = m.to_sym
      end
      opts.on("-i", "--index index", FESIndex.keys, "Set media index " <<
      "(" << FESIndex.keys.join(", ") << ")") do |i|
        $options[:index] = i.to_sym
      end
      opts.on("-t", "--tags t,a,g", Array, "One or more tag (" <<
      AWTags.keys.join(", ") << ")") do |t|
        $options[:tags] = t.map(&:to_sym) # Convert every value to symbol
      end
      opts.on_tail("-v", "--verbose", "Verbose traffic") do
        $options[:verbose] = true
      end
  end.parse!
  $options[:tags] = [:none] unless $options[:tags]
  $options[:mode] = :fel unless $options[:mode]
  # if argument is specfied we want to receive data from the device
  $options[:direction] = [:read, :transmite].include?($options[:action]) ? :read : :write

  unless ($options[:tags] - AWTags.keys).empty?
    puts "Invalid tag. Please specify one or more of " << AWTags.keys.join(", ")
    exit
  end
  raise OptionParser::MissingArgument if($options[:direction] == :read &&
    ($options[:length] == nil || $options[:address] == nil) &&
    [:read, :transmite].include?($options[:action]))
  raise OptionParser::MissingArgument if($options[:direction] == :write &&
     $options[:address] == nil && [:write, :transmite, :run].
     include?($options[:action]))
#  raise OptionParser::MissingArgument if($options[:action] == :read &&
#    ($options[:length] == nil || $options[:address] == nil))
#  raise OptionParser::MissingArgument if(($options[:action] == :write ||
#    $options[:action] == :run) && $options[:address] == nil)
rescue OptionParser::MissingArgument
  puts "Missing argument. Type FELix.rb --help to see usage"
  exit
rescue OptionParser::InvalidArgument
  puts "Invalid argument. Type FELix.rb --help to see usage"
  exit
rescue OptionParser::InvalidOption
  puts "Unknown option. Type FELix.rb --help to see usage"
  exit
end

usb = LIBUSB::Context.new
devices = usb.devices(:idVendor => 0x1f3a, :idProduct => 0xefe8)
if devices.empty?
    puts "No device found in FEL mode!"
    exit
end

if devices.size > 1 && $options[:device] == nil # If there's more than one
                                                # device list and ask to select
    puts "Found more than 1 device (use --device <number> parameter):"
    exit
end
$options[:device] ||= 0

begin
  dev = devices[$options[:device]]
  print "* Connecting to device at port %d, FEL device %d@%d %x:%x" % [
    dev.port_number, dev.bus_number, dev.device_address, dev.idVendor,
    dev.idProduct]

  fel = FELix.new(dev)
  puts "\t[OK]".green

  case $options[:action]
  when :device_info # case for FEL_R_VERIFY_DEVICE
    begin
      info = fel.get_device_info
      info.each_pair do |k, v|
        print "%-40s" % k.to_s.yellow
        case k
        when :board then puts FELHelpers.board_id_to_str(v)
        when :mode then puts AWDeviceMode.key(v)
        when :data_flag, :data_length, :data_start_address then puts "0x%08x" % v
        else
          puts "#{v}"
        end
      end
    rescue => e
      puts "Failed to receive device info (#{e.message})"
    end
  when :format
    begin
      print "* Formating NAND (it may take ~60 seconds)" unless $options[:verbose]
      status = fel.write_mbr($options[:file], true)
      raise "Format failed (#{status.crc})" if status.crc != 0
      puts "\t[OK]".green unless $options[:verbose]
    rescue => e
      puts "\t[FAIL]".red unless $options[:verbose]
      puts "Failed to format device (#{e.message}) at #{e.backtrace.join("\n")}"
    end
  when :mbr
    begin
      print "* Writing MBR" unless $options[:verbose]
      status = fel.write_mbr($options[:file], false)
      raise "Write failed (#{status.crc})" if status.crc != 0
      puts "\t[OK]".green unless $options[:verbose]
    rescue => e
      puts "\t[FAIL]".red unless $options[:verbose]
      puts "Failed to write device (#{e.message}) at #{e.backtrace.join("\n")}"
    end
  when :storage
    begin
      print "* Setting flash state to #{$options[:how]}" unless $options[:verbose]
      fel.set_storage_state($options[:how])
      puts "\t[OK]".green unless $options[:verbose]
    rescue => e
      puts "\t[FAIL]".red unless $options[:verbose]
      puts "Failed to set flash state (#{e.message}) at #{e.backtrace.join("\n")}"
    end
  when :read
    begin
      data = fel.read($options[:address], $options[:length], $options[:tags],
        $options[:mode])
      File.open($options[:file], "w") { |f| f.write(data) }
      puts "\t[OK]".green unless $options[:verbose]
    rescue => e
      puts "\t[FAIL]".red unless $options[:verbose]
      puts "Failed to read data: #{e.message} at #{e.backtrace.join("\n")}"
    end
  when :write
    begin
      print "* #{$options[:mode]}: Reading file" unless $options[:verbose]
      data = File.read($options[:file])
      print " (#{data.bytesize} bytes)" unless $options[:verbose]
      fel.write($options[:address], data, $options[:tags],
        $options[:mode])
      puts "\t[OK]".green unless $options[:verbose]
    rescue => e
      puts "\t[FAIL]".red unless $options[:verbose]
      puts "Failed to write data: #{e.message} at #{e.backtrace.join("\n")}"
    end
  when :run
    begin
      print "* #{$options[:mode]}: Executing code @ 0x%08x" %
        $options[:address] unless $options[:verbose]
      fel.run($options[:address], $options[:mode])
      puts "\t[OK]".green unless $options[:verbose]
    rescue => e
      puts "\t[FAIL]".red unless $options[:verbose]
      puts "Failed to execute: #{e.message} at #{e.backtrace.join("\n")}"
    end
  when :request
    begin
      fel.request($options[:request])
    rescue => e
      puts "Failed to send a request(#{$options[:request]}): #{e.message}" <<
        " at #{e.backtrace.join("\n")}"
    end
  when :transmite
    begin
      if $options[:direction] == :write
        print "* Reading file" unless $options[:verbose]
        data = File.read($options[:file])
        print " (#{data.bytesize} bytes)" unless $options[:verbose]
      end
      data ||= nil
      data = fel.transmite($options[:direction], :address => $options[:address],
        :length => $options[:length], :memory => data, :media_index =>
        $options[:index])
      if $options[:direction] == :read && data
        print "\r* Writing data (#{data.length} bytes )"
        File.open($options[:file], "w") { |f| f.write(data) }
      end
      puts "\t[OK]".green unless $options[:verbose]
    rescue => e
      puts "\t[FAIL]".red unless $options[:verbose]
      puts "Failed to transmite: #{e.message} at #{e.backtrace.join("\n")}"
    end
  else
    puts "No action specified"
  end

rescue LIBUSB::ERROR_NOT_SUPPORTED
  puts "\t[FAIL]".red
  puts "Error: You must install libusb filter on your usb device driver"
rescue => e
  puts "\t[FAIL]".red
  puts "Error: #{e.message} at #{e.backtrace.join("\n")}"
ensure
  # Cleanup the handle
  fel.bailout if fel
end
