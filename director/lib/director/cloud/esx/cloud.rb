module NATS
  class << self
   
    def timed_request(subject, data=nil, opts={})
      # args
      expected = opts[:expected] || 2
      timeout  = opts[:timeout]  || 200

      results = []
      results.extend(MonitorMixin)
      done = results.new_cond

      # Subscribe to responses
      inbox = NATS.create_inbox
      s = NATS.subscribe(inbox) do |msg|
        # This callback happens in the EM.reactor thread.
        results.synchronize do
          done.signal if (results << msg).length == expected
        end
      end

      data.qname = inbox

      # Send request
      publish(subject, data.to_json, inbox)      

      # Wait for results or timeout
      results.synchronize do
        r = done.wait(timeout)
        NATS.unsubscribe(s)
        #NATS.stop
        return r, results.slice(0, expected)
      end
    end

  end
end

module EsxCloud

  class Cloud

    class << self
      attr_accessor :nats_started, :req_id, :lock 
    end

    BOSH_AGENT_PROPERTIES_ID = "Bosh_Agent_Properties"

    attr_accessor :client

    def initialize(options)
      self.class.nats_started = false unless self.class.nats_started
      self.class.req_id = 0 unless self.class.req_id
      self.class.lock = Mutex.new unless self.class.lock

      @logger = Bosh::Director::Config.logger
      @server = "middle"
      @agent_properties = options["agent"]
      @nats = options["nats"]
      @esxmgr = options["esxmgr"]
      @vm_mac = "00:00:00:00:00:00"

      @logger.info("ESXCLOUD: options #{@nats}")
      @logger.info("ESXCLOUD: options #{@esxmgr}")
    end

    def generate_unique_name
      UUIDTools::UUID.random_create.to_s
    end

    def generate_agent_env(name, vm, agent_id, networking_env, disk_env)
      vm_env = {
          "name" => name,
          "id" => vm
      }
      env = {}
      env["vm"] = vm_env
      env["agent_id"] = agent_id
      env["networks"] = networking_env
      env["disks"] = disk_env
      env.merge!(@agent_properties)
      env
    end

    def build_agent_network_env(devices, networks)
      network_env = {}
      networks.each do |network_name, network|
        network_entry = network.dup
        devices.each do |d|
          if d["vswitch"] == network["cloud_properties"]["name"]
            network_entry["mac"] = d["mac"]
            break
          end
        end
        network_env[network_name] = network_entry
      end
      network_env
    end

    def send_request(payload, timeout=nil)
      req_id = 0
      rtn_payload = nil

      # Start NATS 
      self.class.lock.synchronize do
        unless self.class.nats_started
          Thread.new {
            uri = "nats://#{@nats["user"]}:#{@nats["password"]}@#{@nats["host"]}:#{@nats["port"]}"
            @logger.info("ESXCLOUD: starting NATS at #{uri}")
            NATS.start(:uri => uri) {
              @logger.info("ESXCLOUD: now nats_started is true")
              self.class.nats_started = true
            }
            @logger.info("ESXCLOUD: NATS is  S T O P P E D")
          }
          while !self.class.nats_started
            @logger.info("ESXCLOUD: waiting for nats to start")
            sleep(0.1)
          end
        end
        raise "NATS could not be started" unless self.class.nats_started

        # While we have the lock, get our own unique request id
        req_id = self.class.req_id
        self.class.req_id = self.class.req_id + 1
      end

      req = EsxMQ::RequestMsg.new(req_id)
      req.payload = payload

      opts = Hash.new
      opts[:timeout] = timeout if timeout

      @logger.info("ESXCLOUD: sending request #{payload}")
      rtn, results = NATS.timed_request(@nats["qname"], req, opts)
      if rtn
        raise "Bad taskID #{results}" unless results[0]["@taskID"] == results[1]["@taskID"]

        if results[1]["@returnStatus"].downcase == "failure"
          @logger.info("ESXCloud, request #{payload} failed #{results}")
          raise "ESXCloud, request #{payload} failed #{results}"
          rtn = false
        end
      else
          @logger.info("ESXCloud, request #{payload} timedout #{results}")
          raise "ESXCloud, request #{payload} timedout #{results}"
      end
      @logger.info("ESXCloud, request #{payload} rtn #{rtn}, rtn_payload #{rtn_payload}")
      return rtn, rtn_payload
    end


    def send_file(name, full_file_name)
      sock = TCPSocket.open(@esxmgr["host"], EsxMQ::MQ::DEFAULT_FILE_UPLOAD_PORT)
      src_file = open(full_file_name, "rb")

      name = name.ljust(256)
      sock.write(name)

      while (file_content = src_file.read(4096))
        sock.write(file_content)
      end
      sock.flush
      sock.close

      # XXX, Wait for server to receive the last bits, The flush above does not
      #      seem to be working well.
      sleep(5)
    end


    def create_stemcell(image, _)
      with_thread_name("create_stemcell(#{image}, _)") do
        result = nil
        Dir.mktmpdir do |temp_dir|
          @logger.info("Extracting stemcell to: #{temp_dir}, image is #{image}")


          name = "sc-#{generate_unique_name}"
          @logger.info("Generated name: #{name}")

          # upload stemcell to esx controller
          send_file(name, image)

          # send "create stemcell" command to controller
          create_sc = EsxMQ::CreateStemcellMsg.new(name, name)
          rtn, rtn_payload = send_request(create_sc, 3600)
          result = name if rtn
        end
        @logger.info("ESXCLOUD: create_stemcell is returnng <#{result}>")
        result
      end
    end

    def delete_stemcell(stemcell)
      with_thread_name("delete_stemcell(#{stemcell})") do
        # send delete stemcell command to esx controller
        delete_sc = EsxMQ::DeleteStemcellMsg.new(stemcell)
        send_request(delete_sc)
      end
    end

    def create_vm(agent_id, stemcell, resource_pool, networks, disk_locality = nil)
      with_thread_name("create_vm(#{agent_id}, ...)") do
        result = nil

        # TODO do we need to worry about disk locality
        name = "vm-#{generate_unique_name}"
        @logger.info("ESXCLOUD: Creating vm: #{name}")

        create_vm = EsxMQ::CreateVmMsg.new(name)
        create_vm.cpu = resource_pool["cpu"]
        create_vm.ram = resource_pool["ram"]
        devices = []
        networks.each_value do |network|
          net = Hash.new
          net["vswitch"] = network["cloud_properties"]["name"]
          net["mac"] =  @vm_mac
          devices << net
        end

        create_vm.stemcell = stemcell
        # TODO fix these
        system_disk = 0
        ephemeral_disk = 1

        network_env = build_agent_network_env(devices, networks)
        # TODO fix disk_env
        disk_env = { "system" => system_disk,
                     "ephemeral" => ephemeral_disk,
                     "persistent" => {}
        }
        create_vm.guestInfo = generate_agent_env(name, name, agent_id, network_env, disk_env)

        rtn, dummy = send_request(create_vm)
        result = name if rtn
        raise "Create vm Failed" unless rtn
        result
      end
    end

    def delete_vm(vm_cid)
      with_thread_name("delete_vm(#{vm_cid})") do
        @logger.info("ESXCLOUD: Deleting vm: #{vm_cid}")

        delete_vm = EsxMQ::DeleteVmMsg.new(vm_cid)
        send_request(delete_vm)
      end
    end

    def configure_networks(vm_cid, networks)
      with_thread_name("configure_networks(#{vm_cid}, ...)") do
        @logger.info("Configuring: #{vm_cid} to use the following network settings: #{networks.pretty_inspect}")
        raise "ESXCLOUD: configure networks is not implemented yet"
      end
    end

    def attach_disk(vm_cid, disk_cid)
      with_thread_name("attach_disk(#{vm_cid}, #{disk_cid})") do
        @logger.info("Attaching disk: #{disk_cid} on vm: #{vm_cid}")
        raise "ESXCLOUD: attach disk is not implemented yet"
      end
    end

    def detach_disk(vm_cid, disk_cid)
      with_thread_name("detach_disk(#{vm_cid}, #{disk_cid})") do
        @logger.info("Detaching disk: #{disk_cid} from vm: #{vm_cid}")
        raise "ESXCLOUD: Detaching disk is not implemented yet"
      end
    end

    def create_disk(size, _ = nil)
      with_thread_name("create_disk(#{size}, _)") do
        @logger.info("Creating disk with size: #{size}")
        raise "ESXCLOUD: Create disk not implemented yet"
      end
    end

    def delete_disk(disk_cid)
      with_thread_name("delete_disk(#{disk_cid})") do
        @logger.info("Deleting disk: #{disk_cid}")
        raise "ESXCLOUD: Delete disk not implemented yet"
      end
    end

    def validate_deployment(old_manifest, new_manifest)
      # TODO: still needed? what does it verify? cloud properties? should be replaced by normalize cloud properties?
      @logger.info("Validate deployment")
      raise "ESXCLOUD: Validate deployment not implemented yet"
    end
  end
end
