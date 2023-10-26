# coding: utf-8
require "sam"
require "file_utils"
require "colorize"
require "totem"
require "docker_client"
require "halite"
require "totem"
require "k8s_netstat"
require "kernel_introspection"
require "k8s_kernel_introspection"
require "../utils/utils.cr"

desc "The CNF test suite checks to see if CNFs follows microservice principles"
task "microservice", ["reasonable_image_size", "reasonable_startup_time", "single_process_type", "service_discovery", "shared_database", "specialized_init_system", "sig_term_handled"] do |_, args|
  stdout_score("microservice")
  case "#{ARGV.join(" ")}" 
  when /microservice/
    stdout_info "Results have been saved to #{CNFManager::Points::Results.file}".colorize(:green)
  end
end

REASONABLE_STARTUP_BUFFER = 10.0

desc "To check if the CNF has multiple microservices that share a database"
task "shared_database", ["install_cluster_tools"] do |_, args|

  CNFManager::Task.task_runner(args) do |args, config|
    task_start_time = Time.utc
    testsuite_task = "shared_database"
    Log.for(testsuite_task).info { "Starting test" }

    # todo loop through local resources and see if db match found
    db_match = Netstat::Mariadb.match
    
    if db_match[:found] == false
      upsert_na_task(testsuite_task, "⏭️  N/A: [shared_database] No MariaDB containers were found", task_start_time)
      next
    end

    resource_ymls = CNFManager.cnf_workload_resources(args, config) { |resource| resource }
    resource_names = Helm.workload_resource_kind_names(resource_ymls)
    helm_chart_cnf_services : Array(JSON::Any)
    # namespace = CNFManager.namespace_from_parameters(CNFManager.install_parameters(config))
    # Log.info { "namespace: #{namespace}"}
    helm_chart_cnf_services = resource_names.map do |resource_name|
      Log.info { "helm_chart_cnf_services resource_name: #{resource_name}"}
      if resource_name[:kind].downcase == "service"
        #todo check for namespace
        resource = KubectlClient::Get.resource(resource_name[:kind], resource_name[:name], resource_name[:namespace])
      end
      resource
    end.flatten.compact

    Log.info { "helm_chart_cnf_services: #{helm_chart_cnf_services}"}

    db_pod_ips = Netstat::K8s.get_all_db_pod_ips

    cnf_service_pod_ips = [] of Array(NamedTuple(service_group_id: Int32, pod_ips: Array(JSON::Any)))
    helm_chart_cnf_services.each_with_index do |helm_cnf_service, index|
      service_pods = KubectlClient::Get.pods_by_service(helm_cnf_service)
      if service_pods
        cnf_service_pod_ips << service_pods.map { |pod|
          {
            service_group_id: index,
            pod_ips: pod.dig("status", "podIPs").as_a.select{|ip|
              db_pod_ips.select{|dbip| dbip["ip"].as_s != ip["ip"].as_s}
            }
          }

        }.flatten.compact
      end
    end

    cnf_service_pod_ips = cnf_service_pod_ips.compact.flatten
    Log.info { "cnf_service_pod_ips: #{cnf_service_pod_ips}"}


    violators = Netstat::K8s.get_multiple_pods_connected_to_mariadb_violators
    
    Log.info { "violators: #{violators}"}
    Log.info { "cnf_service_pod_ips: #{cnf_service_pod_ips}"}


    cnf_violators = violators.find do |violator|
      cnf_service_pod_ips.find do |service|
        service["pod_ips"].find do |ip|
          violator["ip"].as_s.includes?(ip["ip"].as_s)
        end
      end
    end
    
    Log.info { "cnf_violators: #{cnf_violators}"}

    integrated_database_found = false

    if violators.size > 1 && cnf_violators
      puts "Found multiple pod ips from different services that connect to the same database: #{violators}".colorize(:red)
      integrated_database_found = true 
    end

    failed_emoji = "(ভ_ভ) ރ 💾"
    passed_emoji = "🖥️  💾"
    if integrated_database_found 
      upsert_failed_task(testsuite_task, "✖️  FAILED: Found a shared database #{failed_emoji}", task_start_time)
    else
      upsert_passed_task(testsuite_task, "✔️  PASSED: No shared database found #{passed_emoji}", task_start_time)
    end
  end
end

desc "Does the CNF have a reasonable startup time (< 30 seconds)?"
task "reasonable_startup_time" do |_, args|
  Log.info { "Running reasonable_startup_time test" }
  CNFManager::Task.task_runner(args) do |args, config|
    task_start_time = Time.utc
    testsuite_task = "reasonable_startup_time"
    Log.for(testsuite_task).info { "Starting test" }

    Log.for(testsuite_task).debug { "cnf_config: #{config.cnf_config}" }

    yml_file_path = config.cnf_config[:yml_file_path]
    helm_chart = config.cnf_config[:helm_chart]
    helm_directory = config.cnf_config[:helm_directory]
    release_name = config.cnf_config[:release_name]
    install_method = config.cnf_config[:install_method]

    current_dir = FileUtils.pwd
    helm = Helm::BinarySingleton.helm
    Log.for("verbose").info {helm} if check_verbose(args)

    configmap = KubectlClient::Get.configmap("cnf-testsuite-#{release_name}-startup-information")
    #TODO check if json is empty
    startup_time = configmap["data"].as_h["startup_time"].as_s

    emoji_fast="🚀"
    emoji_slow="🐢"
    # Correlation for a slow box vs a fast box 
    # sysbench base fast machine (disk), time in ms 0.16
    # sysbench base slow machine (disk), time in ms 6.55
    # percentage 0.16 is 2.44% of 6.55
    # How much more is 6.55 than 0.16? (0.16 - 6.55) / 0.16 * 100 = 3993.75%
    # startup time fast machine: 21 seconds
    # startup slow machine: 34 seconds
    # how much more is 34 seconds than 21 seconds? (21 - 34) / 21 * 100 = 61.90%
    # app seconds set 1: 21, set 2: 34
    # disk miliseconds set 1: .16 set 2: 6.55
    # get the mean of app seconds (x)
    #   (sum all: 55, count number of sets: 2, divide sum by count: 27.5)
    # get the mean of disk milliseconds (y)
    #   (sum all: 6.71, count number of sets: 2, divide sum by count: 3.35)
    # Subtract the mean of x from every x value (call them "a")
    # set 1: 6.5 
    # set 2: -6.5 
    # and subtract the mean of y from every y value (call them "b")
    # set 1: 3.19
    # set 2: -3.2
    # calculate: ab, a2 and b2 for every value
    # set 1: 20.735, 42.25, 42.25
    # set 2: 20.8, 10.17, 10.24
    # Sum up ab, sum up a2 and sum up b2
    # 41.535, 52.42, 52.49
    # Divide the sum of ab by the square root of [(sum of a2) × (sum of b2)]
    # (sum of a2) × (sum of b2) = 2751.5258
    # square root of 2751.5258 = 52.4549
    # divide sum of ab by sqrt = 41.535 / 52.4549 = .7918
    # example
    # sysbench returns a 5.55 disk millisecond result
    # disk millisecond has a pearson correlation of .79 to app seconds
    # 
    # Regression for predication based on slow and fast box disk times
    # regression = ŷ = bX + a
    # b = 2.02641
    # a = 20.72663

    resp = K8sInstrumentation.disk_speed
    if resp["95th percentile"]?
        disk_speed = resp["95th percentile"].to_f
      startup_time_limit = ((0.30593 * disk_speed) + 21.9162 + REASONABLE_STARTUP_BUFFER).round.to_i
    else
      startup_time_limit = 30
    end
    # if ENV["CRYSTAL_ENV"]? == "TEST"
    #   startup_time_limit = 35 
    #   LOGGING.info "startup_time_limit TEST mode: #{startup_time_limit}"
    # end
    Log.info { "startup_time_limit: #{startup_time_limit}" }
    Log.info { "startup_time: #{startup_time.to_i}" }

    if startup_time.to_i <= startup_time_limit
      upsert_passed_task(testsuite_task, "✔️  PASSED: CNF had a reasonable startup time #{emoji_fast}", task_start_time)
    else
      upsert_failed_task(testsuite_task, "✖️  FAILED: CNF had a startup time of #{startup_time} seconds #{emoji_slow}", task_start_time)
    end

  end
end

# There aren't any 5gb images to test.
# To run this test in a test environment or for testing purposes,
# set the env var CRYSTAL_ENV=TEST when running the test.
#
# Example:
#    CRYSTAL_ENV=TEST ./cnf-testsuite reasonable_image_size
#
desc "Does the CNF have a reasonable container image size (< 5GB)?"
task "reasonable_image_size" do |_, args|
  CNFManager::Task.task_runner(args) do |args,config|
    task_start_time = Time.utc
    testsuite_task = "reasonable_image_size"
    Log.for(testsuite_task).info { "Starting test" }

    docker_insecure_registries = [] of String
    if config.cnf_config[:docker_insecure_registries]? && !config.cnf_config[:docker_insecure_registries].nil?
      docker_insecure_registries = config.cnf_config[:docker_insecure_registries].not_nil!
    end
    unless Dockerd.install(docker_insecure_registries)
      upsert_skipped_task(testsuite_task, "⏭️  SKIPPED: Skipping reasonable_image_size: Dockerd tool failed to install", task_start_time)
      next
    end

    Log.for(testsuite_task).debug { "cnf_config: #{config}" }
    task_response = CNFManager.workload_resource_test(args, config) do |resource, container, initialized|

      yml_file_path = config.cnf_config[:yml_file_path]

      if resource["kind"].downcase == "deployment" ||
          resource["kind"].downcase == "statefulset" ||
          resource["kind"].downcase == "pod" ||
          resource["kind"].downcase == "replicaset"
				test_passed = true

				image_url = container.as_h["image"].as_s
        image_url_parts = image_url.split("/")
        image_host = image_url_parts[0]

        # Set default FQDN value
        fqdn_image = image_url

        # If FQDN mapping is available for the registry,
        # replace the host in the fqdn_image
        if config.cnf_config[:image_registry_fqdns]? && !config.cnf_config[:image_registry_fqdns].nil?
          image_registry_fqdns = config.cnf_config[:image_registry_fqdns].not_nil!
          if image_registry_fqdns[image_host]?
            image_url_parts[0] = image_registry_fqdns[image_host]
            fqdn_image = image_url_parts.join("/")
          end
        end

        image_pull_secrets = KubectlClient::Get.resource(resource[:kind], resource[:name], resource[:namespace]).dig?("spec", "template", "spec", "imagePullSecrets")
        if image_pull_secrets
          auths = image_pull_secrets.as_a.map { |secret|
            puts secret["name"]
            secret_data = KubectlClient::Get.resource("Secret", "#{secret["name"]}", resource[:namespace]).dig?("data")
            if secret_data
              dockerconfigjson = Base64.decode_string("#{secret_data[".dockerconfigjson"]}")
              dockerconfigjson.gsub(%({"auths":{),"")[0..-3]
              # parsed_dockerconfigjson = JSON.parse(dockerconfigjson)
              # parsed_dockerconfigjson["auths"].to_json.gsub("{","").gsub("}", "")
            else
              # JSON.parse(%({}))
              ""
            end
          }
          if auths
            str_auths = %({"auths":{#{auths.reduce("") { | acc, x|
            acc + x.to_s + ","
          }[0..-2]}}})
            puts "str_auths: #{str_auths}"
          end
          File.write("#{yml_file_path}/config.json", str_auths)
          Dockerd.exec("mkdir -p /root/.docker/")
          KubectlClient.cp("#{yml_file_path}/config.json #{TESTSUITE_NAMESPACE}/dockerd:/root/.docker/config.json")
        end

        Log.info { "FQDN of the docker image: #{fqdn_image}" }
        Dockerd.exec("docker pull #{fqdn_image}")
        Dockerd.exec("docker save #{fqdn_image} -o /tmp/image.tar")
        Dockerd.exec("gzip -f /tmp/image.tar")
        exec_resp = Dockerd.exec("wc -c /tmp/image.tar.gz | awk '{print$1}'")
        compressed_size = exec_resp[:output]
        # TODO strip out secret from under auths, save in array
        # TODO make a new auths array, assign previous array into auths array
        # TODO save auths array to a file
        Log.info { "compressed_size: #{fqdn_image} = '#{compressed_size.to_s}'" }
        max_size = 5_000_000_000
        if ENV["CRYSTAL_ENV"]? == "TEST"
           Log.info { "Using Test Mode max_size" }
           max_size = 16_000_000
        end

        begin
          unless compressed_size.to_s.to_i64 < max_size
            puts "resource: #{resource} and container: #{fqdn_image} was more than #{max_size}".colorize(:red)
            test_passed=false
          end
        rescue ex
          Log.for(testsuite_task).error { "invalid compressed_size: #{fqdn_image} = '#{compressed_size.to_s}', #{ex.message}".colorize(:red) }
          test_passed = false
        end
      else
        test_passed = true
      end
      test_passed
    end

    emoji_image_size="⚖️👀"
    emoji_small="🐜"
    emoji_big="🦖"

    if task_response
      upsert_passed_task(testsuite_task, "✔️  PASSED: Image size is good #{emoji_small} #{emoji_image_size}", task_start_time)
    else
      upsert_failed_task(testsuite_task, "✖️  FAILED: Image size too large #{emoji_big} #{emoji_image_size}", task_start_time)
    end
  end
end

desc "Do the containers in a pod have only one process type?"
task "process_search" do |_, args|
  pod_info = KernelIntrospection::K8s.find_first_process("sleep 30000")
  puts "pod_info: #{pod_info}"
  proctree = KernelIntrospection::K8s::Node.proctree_by_pid(pod_info[:pid], pod_info[:node]) if pod_info
  puts "proctree: #{proctree}"

end

desc "Do the containers in a pod have only one process type?"
task "single_process_type" do |_, args|
  CNFManager::Task.task_runner(args) do |args,config|
    task_start_time = Time.utc
    testsuite_task = "single_process_type"
    Log.for(testsuite_task).info { "Starting test" }

    Log.for(testsuite_task).debug { "cnf_config: #{config}" }
    fail_msgs = [] of String
    all_node_proc_statuses = [] of NamedTuple(node_name: String,
                                              proc_statuses: Array(String))

    task_response = CNFManager.workload_resource_test(args, config) do |resource, container, initialized|
      test_passed = true
      kind = resource["kind"].downcase
      case kind 
      when  "deployment","statefulset","pod","replicaset", "daemonset"
        resource_yaml = KubectlClient::Get.resource(resource[:kind], resource[:name], resource[:namespace])
        pods = KubectlClient::Get.pods_by_resource(resource_yaml)
        containers = KubectlClient::Get.resource_containers(kind, resource[:name], resource[:namespace])
        pods.map do |pod|
          pod_name = pod.dig("metadata", "name")
          Log.for(testsuite_task).info { "pod_name: #{pod_name}" }

          status = pod["status"]
          if status["containerStatuses"]?
              container_statuses = status["containerStatuses"].as_a
            Log.for(testsuite_task).info { "container_statuses: #{container_statuses}" }
            Log.for(testsuite_task).info { "pod_name: #{pod_name}" }
            nodes = KubectlClient::Get.nodes_by_pod(pod)
            Log.for(testsuite_task).info { "nodes_by_resource done" }
            node = nodes.first
            container_statuses.map do |container_status|
              container_name = container_status.dig("name")
              previous_process_type = "initial_name"
              container_id = container_status.dig("containerID").as_s
              ready = container_status.dig("ready").as_bool
              next unless ready 
              Log.for(testsuite_task).info { "containerStatuses container_id #{container_id}" }

              pid = ClusterTools.node_pid_by_container_id(container_id, node)
              Log.for(testsuite_task).info { "node pid (should never be pid 1): #{pid}" }

              next unless pid

              node_name = node.dig("metadata", "name").as_s
              Log.for(testsuite_task).info { "node name : #{node_name}" }
#              filtered_proc_statuses = all_node_proc_statuses.find {|x| x[:node_name] == node_name}
#              proc_statuses = filtered_proc_statuses ? filtered_proc_statuses[:proc_statuses] : nil
#              Log.debug { "node statuses : #{proc_statuses}" }
#              unless proc_statuses 
#                Log.info { "node statuses not found" }
                pids = KernelIntrospection::K8s::Node.pids(node) 
                Log.info { "proctree_by_pid pids: #{pids}" }
                proc_statuses = KernelIntrospection::K8s::Node.all_statuses_by_pids(pids, node)
#                all_node_proc_statuses << {node_name: node_name,
#                                     proc_statuses:  proc_statuses} 

 #             end
              statuses = KernelIntrospection::K8s::Node.proctree_by_pid(pid, 
                                                                          node, 
                                                                          proc_statuses)

              statuses.map do |status|
                Log.for(testsuite_task).debug { "status: #{status}" }
                Log.for(testsuite_task).info { "status cmdline: #{status["cmdline"]}" }
                status_name = status["Name"].strip
                ppid = status["PPid"].strip
                Log.for(testsuite_task).info { "status name: #{status_name}" }
                Log.for(testsuite_task).info { "previous status name: #{previous_process_type}" }
                # Fail if more than one process type
                #todo make work if processes out of order
                if status_name != previous_process_type && 
                    previous_process_type != "initial_name"
                    
                  verified = KernelIntrospection::K8s::Node.verify_single_proc_tree(ppid, 
                                                                                    status_name, 
                                                                                    statuses)
                  unless verified  
                    Log.for(testsuite_task).info { "multiple proc types detected verified: #{verified}" }
                    fail_msg = "resource: #{resource}, pod #{pod_name} and container: #{container_name} has more than one process type (#{statuses.map{|x|x["cmdline"]?}.compact.uniq.join(", ")})"
                    unless fail_msgs.find{|x| x== fail_msg}
                      puts fail_msg.colorize(:red)
                      fail_msgs << fail_msg
                    end
                    test_passed=false
                  end
                end
                previous_process_type = status_name
              end
            end
          end
        end
        test_passed
      end
    end
    emoji_image_size="⚖️👀"
    emoji_small="🐜"
    emoji_big="🦖"

    if task_response
      upsert_passed_task(testsuite_task, "✔️  🏆 PASSED: Only one process type used #{emoji_small} #{emoji_image_size}", task_start_time)
    else
      upsert_failed_task(testsuite_task, "✖️  🏆 FAILED: More than one process type used #{emoji_big} #{emoji_image_size}", task_start_time)
    end
  end
end

desc "Are the SIGTERM signals handled?"
task "zombie_handled" do |_, args|
  CNFManager::Task.task_runner(args) do |args,config|
    task_start_time = Time.utc
    testsuite_task = "zombie_handled"
    Log.for(testsuite_task).info { "Starting test" }

    Log.for(testsuite_task).debug { "cnf_config: #{config}" }

    task_response = CNFManager.workload_resource_test(args, config, check_containers:false ) do |resource, container, initialized|
      ClusterTools.all_containers_by_resource?(resource, resource[:namespace]) do | container_id, container_pid_on_node, node, container_proctree_statuses, container_status| 
        resp = ClusterTools.exec_by_node("runc --root /run/containerd/runc/k8s.io/ state #{container_id}", node)
        Log.for(testsuite_task).info { "resp[:output] #{resp[:output]}" }
        bundle_path = JSON.parse(resp[:output].to_s)
        Log.for(testsuite_task).info { "bundle path: #{bundle_path["bundle"]} "}
        ClusterTools.exec_by_node("nerdctl --namespace=k8s.io cp /zombie #{container_id}:/zombie", node)
        ClusterTools.exec_by_node("nerdctl --namespace=k8s.io cp /sleep #{container_id}:/sleep", node)
        # ClusterTools.exec_by_node("ctools --bundle_path <bundle_path > --container_id <container_id>")
        ClusterTools.exec_by_node("runc --root /run/containerd/runc/k8s.io/ exec --pid-file #{bundle_path["bundle"]}/init.pid #{container_id} /zombie", node)
      end
    end

    sleep 10.0

    task_response = CNFManager.workload_resource_test(args, config, check_containers:false ) do |resource, container, initialized|
      ClusterTools.all_containers_by_resource?(resource, resource[:namespace]) do | container_id, container_pid_on_node, node, container_proctree_statuses, container_status| 

        zombies = container_proctree_statuses.map do |status|
          Log.for(testsuite_task).debug { "status: #{status}" }
          Log.for(testsuite_task).info { "status cmdline: #{status["cmdline"]}" }
          status_name = status["Name"].strip
          current_pid = status["Pid"].strip
          state = status["State"].strip
          Log.for(testsuite_task).info { "pid: #{current_pid}" }
          Log.for(testsuite_task).info { "status name: #{status_name}" }
          Log.for(testsuite_task).info { "state: #{state}" }
          Log.for(testsuite_task).info { "(state =~ /zombie/): #{(state =~ /zombie/)}" }
          if (state =~ /zombie/) != nil
            puts "Process #{status_name} has a state of #{state}".colorize(:red)
            true
          else 
            nil
          end
        end
        Log.for(testsuite_task).info { "zombies.all?(nil): #{zombies.all?(nil)}" }
        zombies.all?(nil)
      end
    end

    emoji_image_size="⚖️👀"
    emoji_small="🐜"
    emoji_big="🦖"

    if task_response
      upsert_passed_task(testsuite_task, "✔️  🏆 PASSED: Zombie handled #{emoji_small} #{emoji_image_size}", task_start_time)
    else
      upsert_failed_task(testsuite_task, "✖️  🏆 FAILED: Zombie not handled #{emoji_big} #{emoji_image_size}", task_start_time)
    end
  end

end



desc "Are the SIGTERM signals handled?"
task "sig_term_handled" do |_, args|
  CNFManager::Task.task_runner(args) do |args,config|
    task_start_time = Time.utc
    testsuite_task = "sig_term_handled"
    Log.for(testsuite_task).info { "Starting test" }

    Log.for(testsuite_task).debug { "cnf_config: #{config}" }

    # test_status can be "skipped" or "failed".
    #   Only collecting containers that failed or were skipped.
    #
    # test_reason can be "No Node PID found" or "Not ready".
    #   Only available when when test is skipped.
    failed_containers = [] of NamedTuple(
      namespace: String,
      pod: String,
      container: String,
      test_status: String,
      test_reason: String | Nil
    )

    task_response = CNFManager.workload_resource_test(args, config, check_containers:false ) do |resource, container, initialized|
      test_passed = true
      # todo Clustertools.each_container_by_resource(resource, namespace) do | container_id, container_pid_on_node, node, container_proctree_statuses, container_status| 
      kind = resource["kind"].downcase
      case kind 
      when  "deployment","statefulset","pod","replicaset", "daemonset"
        resource_yaml = KubectlClient::Get.resource(resource[:kind], resource[:name], resource[:namespace])
        #todo needs namespace
        pods = KubectlClient::Get.pods_by_resource(resource_yaml, resource[:namespace])
        # containers = KubectlClient::Get.resource_containers(kind, resource[:name], resource[:namespace])
        #todo loop through containers (we only need to process each image per deployment.  skip images that were already processed)
        # --- skipped because could have same image but started with different startup commands which would instantiate different processes
        # sig_term_found = false
        pid_log_names  = [] of String
        pod_sig_terms = pods.map do |pod|
          #todo get the host pid from the container pid
          pod_name = pod.dig("metadata", "name").as_s
          pod_namespace = pod.dig("metadata", "namespace").as_s
          Log.info { "pod_name: #{pod_name}" }

          # Wait for a pod to be available. Only wait for 20 seconds.
          KubectlClient::Get.wait_for_resource_availability("pod", pod_name, pod_namespace, 60)

          status = pod["status"]
          if status["containerStatuses"]?
              container_statuses = status["containerStatuses"].as_a
            Log.for(testsuite_task).info { "container_statuses: #{container_statuses}" }
            Log.for(testsuite_task).info { "pod_name: #{pod_name}" }
            nodes = KubectlClient::Get.nodes_by_pod(pod)
            Log.for(testsuite_task).info { "nodes_by_resource done" }
            node = nodes.first # there should only be one node returned for one pod
            sig_result = container_statuses.map do |container_status|
              container_name = container_status.dig("name")
              previous_process_type = "initial_name"

              # Check if the container status is ready.
              # If this container is not ready, move on to next.
              container_name = container_status.dig("name").as_s
              Log.for(testsuite_task).info { "before ready containerStatuses pod:#{pod_name} container:#{container_name}" }
              ready = container_status.dig("ready").as_bool
              if !ready
                Log.info { "container status: #{container_status} "}
                Log.info { "not ready! skipping: containerStatuses pod:#{pod_name} container:#{container_name}" }
                failed_containers << {
                  namespace: pod_namespace,
                  pod: pod_name,
                  container: container_name,
                  test_status: "skipped",
                  test_reason: "Not ready"
                }
                false
                next
              end

              container_id = container_status.dig("containerID").as_s
              Log.for(testsuite_task).info { "containerStatuses container_id #{container_id}" }

              #get container id's pid on the node (different from inside the container)
              pid = "#{ClusterTools.node_pid_by_container_id(container_id, node)}"
              if pid.empty?
                Log.info { "no pid for (skipping): containerStatuses container_id #{container_id}" }
                failed_containers << {
                  namespace: pod_namespace,
                  pod: pod_name,
                  container: container_name,
                  test_status: "skipped",
                  test_reason: "No Node PID found"
                }
                false
                next
              end

              # next if pid.empty?
              Log.for(testsuite_task).info { "node pid (should never be pid 1): #{pid}" }

              # need to do the next line.  how to kill the current cnf?
              # this was one of the reason why we did stuff like this durring the cnf install and saved it as a configmap
              #todo 1. Kill PID one in container/ send term signal
              #Kill Container, with top level pid
              #todo 2.2.1 kill 1 
            #  ClusterTools.exec("kill #{pid}")
              #todo  1.1 get in container
              #todo 2. Watch for signals for the containers pid one process, and the tree of all child processes ity manages
              #todo 2.1 loop through all child processes that are not threads (only include proceses where tgid = pid)
              #todo 2.1.1 ignore the parent pid (we are on the host so it wont be pid 1)
              node_name = node.dig("metadata", "name").as_s
              Log.for(testsuite_task).info { "node name : #{node_name}" }
              pids = KernelIntrospection::K8s::Node.pids(node) 
              Log.for(testsuite_task).info { "proctree_by_pid pids: #{pids}" }
              proc_statuses = KernelIntrospection::K8s::Node.all_statuses_by_pids(pids, node)

              statuses = KernelIntrospection::K8s::Node.proctree_by_pid(pid, node, proc_statuses)

              non_thread_statuses = statuses.reduce([] of Hash(String, String)) do |acc, i|
                current_pid = i["Pid"].strip
                tgid = i["Tgid"].strip # check if 'g' is uppercase
                Log.info { "#{tgid} && #{tgid} != #{current_pid}: #{tgid && tgid != current_pid}" }
                if tgid && tgid == current_pid
                  acc << i
                elsif tgid.empty?
                  acc << i
                else
                  acc
                end
              end
              non_thread_statuses.map do |status|
                Log.for(testsuite_task).debug { "status: #{status}" }
                Log.for(testsuite_task).info { "status cmdline: #{status["cmdline"]}" }
                status_name = status["Name"].strip
                ppid = status["PPid"].strip
                current_pid = status["Pid"].strip
                tgid = status["Tgid"].strip # check if 'g' is uppercase
                Log.for(testsuite_task).info { "Pid: #{current_pid}" }
                Log.for(testsuite_task).info { "Tgid: #{tgid}" }
                Log.for(testsuite_task).info { "status name: #{status_name}" }
                Log.for(testsuite_task).info { "previous status name: #{previous_process_type}" }
                # do not count the top pid if there are children
                if non_thread_statuses.size > 1 && pid == current_pid 
                  next
                end
                #todo 5. Make sure that threads are not counted as new processes.  A thread does not get a signal (sigterm or sigkill)
                # Log.info { "#{tgid} && #{tgid} != #{current_pid}: #{tgid && tgid != current_pid}" }
                # next if tgid && tgid != current_pid
                #todo 2.2 strace -p <pid> -e 'trace=!all'
                #Watch strace
                #todo 2.2.1 try writing to a file or live?
                pid_log_name = "/tmp/#{current_pid}-strace"
                ClusterTools.exec_by_node_bg("strace -p #{current_pid} -e 'trace=!all' 2>&1 | tee #{pid_log_name}", node)
                pid_log_names << pid_log_name


                # todo save off all directory/filenames into a hash
                #strace: Process 94273 attached
                # ---SIGURG {si_signo=SIGURG, si_code=SI_TKILL, si_pid=1, si_uid=0} ---
                # --- SIGTERM {si_signo=SIGTERM, si_code=SI_USER, si_pid=0, si_uid=0} ---
                #todo 2.2 wait for 30 seconds
              end
              ClusterTools.exec_by_node("bash -c 'sleep 10 && kill #{pid} && sleep 5 && kill -9 #{pid}'", node)
              Log.for(testsuite_task).info { "pid_log_names: #{pid_log_names}" }
              #todo 2.3 parse the logs 
              #todo get the log
              sleep 5
              sig_term_found = pid_log_names.map do |pid_name|
                Log.info { "pid_name: #{pid_name}" }
                resp = File.read("#{pid_name}")
                if resp
                  Log.info { "resp: #{resp}" }
                  if resp =~ /SIGTERM/ 
                    true
                  else
                    Log.info { "resp: #{resp}" }
                    false
                  end
                else
                  false
                end
              end
              Log.for(testsuite_task).info { "SigTerm Found: #{sig_term_found}" }
              # per all containers
              container_sig_term_check = sig_term_found.all?(true)
              if container_sig_term_check == false
                failed_containers << {
                  namespace: pod_namespace,
                  pod: pod_name,
                  container: container_name,
                  test_status: "failed",
                  test_reason: nil
                }
              end

              container_sig_term_check
              # todo save off all directory/filenames into a hash
              #todo make a clustertools that gets a files contents
              #todo 3. Collect all signals sent, if SIGKILL is captured, application fails test because it doesn't exit child processes cleanly
              #todo 4. Collect all signals sent, if SIGTERM is captured, application pass test because it  exits child processes cleanly
            end
            sig_result.all?(true)
          else
            false
          end 
        end
        pod_sig_terms.all?(true)
      else
        true # non "deployment","statefulset","pod","replicaset", and "daemonset" don't need a sigterm check
      end
    end	
    emoji_image_size="⚖️👀"
    emoji_small="🐜"
    emoji_big="🦖"

    if task_response
      upsert_passed_task(testsuite_task, "✔️  🏆 PASSED: Sig Term handled #{emoji_small} #{emoji_image_size}", task_start_time)
    else
      upsert_failed_task(testsuite_task, "✖️  🏆 FAILED: Sig Term not handled #{emoji_big} #{emoji_image_size}", task_start_time)
      failed_containers.map do |failure_info|
        resource_output = "Pod: #{failure_info["pod"]}, Container: #{failure_info["container"]}, Result: #{failure_info["test_status"]}"
        if failure_info["test_status"] == "skipped"
          resource_output = "#{resource_output}, Reason: #{failure_info["test_reason"]}"
        end
        stdout_failure resource_output
      end
      nil
    end
  end
end

desc "Are any of the containers exposed as a service?"
task "service_discovery" do |_, args|
  CNFManager::Task.task_runner(args) do |args,config|
    task_start_time = Time.utc
    testsuite_task = "service_discovery"
    Log.for(testsuite_task).info { "Starting test" }

    # Get all resources for the CNF
    resource_ymls = CNFManager.cnf_workload_resources(args, config) { |resource| resource }
    default_namespace = "default"
    if !config.cnf_config[:helm_install_namespace].empty?
      default_namespace = config.cnf_config[:helm_install_namespace]
    end
    resources = Helm.workload_resource_kind_names(resource_ymls, default_namespace)

    # Collect service names from the CNF resource list
    cnf_service_names = [] of String
    resources.each do |resource|
      case resource[:kind].downcase
      when "service"
        cnf_service_names.push(resource[:name])
      end
    end

    # Get all the pods in the cluster
    pods = KubectlClient::Get.pods().dig("items").as_a

    # Get pods for the services in the CNF based on the labels
    test_passed = false
    KubectlClient::Get.services(all_namespaces: true).dig("items").as_a.each do |service_info|
      # Only check for pods for services that are defined by the CNF
      service_name = service_info["metadata"]["name"]
      next unless cnf_service_names.includes?(service_name)

      # Some services may not have selectors defined. Example: service/kubernetes
      pod_selector = service_info.dig?("spec", "selector")
      next unless pod_selector

      # Fetch matching pods for the CNF
      # If any service has a matching pod, then mark test as passed
      matching_pods = KubectlClient::Get.pods_by_labels(pods, pod_selector.as_h)
      if matching_pods.size > 0
        Log.debug { "Matching pods for service #{service_name}: #{matching_pods.inspect}" }
        test_passed = true
      end
    end

    emoji_image_size="⚖️👀"
    emoji_small="🐜"
    emoji_big="🦖"

    if test_passed
      upsert_passed_task(testsuite_task, "✔️  ✨PASSED: Some containers exposed as a service #{emoji_small} #{emoji_image_size}", task_start_time)
    else
      upsert_failed_task(testsuite_task, "✖️  ✨FAILED: No containers exposed as a service #{emoji_big} #{emoji_image_size}", task_start_time)
    end
  end
end

desc "To check if the CNF uses a specialized init system"
task "specialized_init_system", ["install_cluster_tools"] do |_, args|
  CNFManager::Task.task_runner(args) do |args, config|
    task_start_time = Time.utc
    testsuite_task = "specialized_init_system"
    Log.for(testsuite_task).info { "Starting test" }

    failed_cnf_resources = [] of InitSystems::InitSystemInfo
    CNFManager.workload_resource_test(args, config) do |resource, container, initialized|
      kind = resource["kind"].downcase
      case kind 
      when  "deployment","statefulset","pod","replicaset", "daemonset"
        namespace = resource[:namespace]
        Log.for(testsuite_task).info { "Checking resource #{resource[:kind]}/#{resource[:name]} in #{namespace}" }
        resource_yaml = KubectlClient::Get.resource(resource[:kind], resource[:name], resource[:namespace])
        pods = KubectlClient::Get.pods_by_resource(resource_yaml, namespace)
        Log.for(testsuite_task).info { "Pod count for resource #{resource[:kind]}/#{resource[:name]} in #{namespace}: #{pods.size}" }
        pods.each do |pod|
          results = InitSystems.scan(pod)
          failed_cnf_resources = failed_cnf_resources + results
        end
      end
    end

    failed_emoji = "(ভ_ভ) ރ 🚀"
    passed_emoji = "🖥️  🚀"

    if failed_cnf_resources.size > 0
      upsert_failed_task(testsuite_task, "✖️  FAILED: Containers do not use specialized init systems #{failed_emoji}", task_start_time)
      failed_cnf_resources.each do |init_info|
        stdout_failure "#{init_info.kind}/#{init_info.name} has container '#{init_info.container}' with #{init_info.init_cmd} as init process"
      end
    else
      upsert_passed_task(testsuite_task, "✔️  PASSED: Containers use specialized init systems #{passed_emoji}", task_start_time)
    end

  end
end
