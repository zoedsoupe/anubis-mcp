# complex_benchmark.exs

defmodule Complex do
  import Peri

  defschema(:organization, %{
    id: {:required, :string},
    metadata:
      {:required,
       %{
         created_at: {:required, :naive_datetime},
         updated_at: {:required, :naive_datetime},
         version: {:required, :integer},
         tags: {:list, :string}
       }},
    configuration:
      {:required,
       %{
         features:
           {:required,
            %{
              authentication: %{
                providers:
                  {:list,
                   %{
                     type: {:enum, [:oauth, :saml, :local]},
                     settings: %{
                       client_id: :string,
                       client_secret: :string,
                       scopes: {:list, :string},
                       redirect_urls: {:list, :string}
                     },
                     rate_limiting: %{
                       enabled: :boolean,
                       max_requests: {:integer, {:gt, 0}},
                       time_window: {:integer, {:gt, 0}}
                     }
                   }},
                session: %{
                  timeout: {:integer, {:gt, 0}},
                  refresh_token: %{
                    enabled: :boolean,
                    expiry: {:integer, {:gt, 0}}
                  }
                }
              },
              storage: %{
                providers:
                  {:list,
                   %{
                     type: {:enum, [:s3, :gcs, :azure]},
                     region: :string,
                     bucket: :string,
                     credentials: %{
                       access_key: :string,
                       secret_key: :string,
                       token: :string
                     },
                     settings: %{
                       encryption: %{
                         enabled: :boolean,
                         algorithm: {:enum, [:aes256, :kms]},
                         key_rotation: {:integer, {:gt, 0}}
                       },
                       compression: %{
                         enabled: :boolean,
                         algorithm: {:enum, [:gzip, :zstd]},
                         level: {:integer, {:range, {1, 9}}}
                       }
                     }
                   }}
              },
              notifications: %{
                channels:
                  {:list,
                   %{
                     type: {:enum, [:email, :sms, :push, :webhook]},
                     enabled: :boolean,
                     provider: %{
                       name: :string,
                       api_key: :string,
                       settings: %{
                         retries: {:integer, {:range, {0, 5}}},
                         timeout: {:integer, {:gt, 0}},
                         template: %{
                           enabled: :boolean,
                           id: :string,
                           variables: {:list, :string}
                         }
                       }
                     }
                   }},
                default_settings: %{
                  throttling: %{
                    enabled: :boolean,
                    max_per_hour: {:integer, {:gt, 0}},
                    cooldown: {:integer, {:gt, 0}}
                  },
                  scheduling: %{
                    timezone: :string,
                    quiet_hours:
                      {:list,
                       %{
                         start: :string,
                         end: :string,
                         days: {:list, {:enum, [:mon, :tue, :wed, :thu, :fri, :sat, :sun]}}
                       }}
                  }
                }
              }
            }},
         security:
           {:required,
            %{
              encryption_at_rest: %{
                enabled: :boolean,
                key_management: %{
                  provider: {:enum, [:aws, :gcp, :azure]},
                  key_rotation_period: {:integer, {:gt, 0}},
                  auto_rotation: :boolean
                }
              },
              network: %{
                allowed_ips: {:list, :string},
                vpn: %{
                  enabled: :boolean,
                  provider: :string,
                  settings: %{
                    protocols: {:list, :string},
                    ports: {:list, :integer}
                  }
                }
              },
              audit: %{
                enabled: :boolean,
                retention: {:integer, {:gt, 0}},
                storage: %{
                  type: {:enum, [:local, :remote]},
                  settings: %{
                    path: :string,
                    format: {:enum, [:json, :csv]}
                  }
                }
              }
            }}
       }},
    resources:
      {:list,
       %{
         id: {:required, :string},
         type: {:required, {:enum, [:compute, :storage, :network]}},
         status: {:required, {:enum, [:active, :inactive, :error]}},
         metadata: %{
           created_at: :naive_datetime,
           updated_at: :naive_datetime,
           labels: {:list, :string}
         },
         specs: %{
           compute: %{
             cpu: {:integer, {:gt, 0}},
             memory: {:integer, {:gt, 0}},
             gpu: %{
               enabled: :boolean,
               count: {:integer, {:gte, 0}},
               type: :string
             }
           },
           storage: %{
             size: {:integer, {:gt, 0}},
             type: {:enum, [:ssd, :hdd]},
             iops: {:integer, {:gt, 0}}
           },
           network: %{
             bandwidth: {:integer, {:gt, 0}},
             public_ip: :boolean,
             dns: %{
               enabled: :boolean,
               records:
                 {:list,
                  %{
                    type: {:enum, [:a, :aaaa, :cname, :mx]},
                    name: :string,
                    value: :string,
                    ttl: {:integer, {:gt, 0}}
                  }}
             }
           }
         }
       }}
  })

  def generate_valid_data do
    %{
      id: "org_#{:crypto.strong_rand_bytes(16) |> Base.encode16()}",
      metadata: %{
        created_at: NaiveDateTime.utc_now(),
        updated_at: NaiveDateTime.utc_now(),
        version: 1,
        tags: ["production", "main"]
      },
      configuration: %{
        features: %{
          authentication: %{
            providers: [
              %{
                type: :oauth,
                settings: %{
                  client_id: "client_123",
                  client_secret: "secret_456",
                  scopes: ["read", "write"],
                  redirect_urls: ["https://example.com/callback"]
                },
                rate_limiting: %{
                  enabled: true,
                  max_requests: 1000,
                  time_window: 3600
                }
              }
            ],
            session: %{
              timeout: 3600,
              refresh_token: %{
                enabled: true,
                expiry: 86400
              }
            }
          },
          storage: %{
            providers: [
              %{
                type: :s3,
                region: "us-east-1",
                bucket: "my-bucket",
                credentials: %{
                  access_key: "access_123",
                  secret_key: "secret_456",
                  token: "token_789"
                },
                settings: %{
                  encryption: %{
                    enabled: true,
                    algorithm: :aes256,
                    key_rotation: 90
                  },
                  compression: %{
                    enabled: true,
                    algorithm: :gzip,
                    level: 6
                  }
                }
              }
            ]
          },
          notifications: %{
            channels: [
              %{
                type: :email,
                enabled: true,
                provider: %{
                  name: "smtp",
                  api_key: "key_123",
                  settings: %{
                    retries: 3,
                    timeout: 30,
                    template: %{
                      enabled: true,
                      id: "template_123",
                      variables: ["name", "content"]
                    }
                  }
                }
              }
            ],
            default_settings: %{
              throttling: %{
                enabled: true,
                max_per_hour: 100,
                cooldown: 300
              },
              scheduling: %{
                timezone: "UTC",
                quiet_hours: [
                  %{
                    start: "22:00",
                    end: "06:00",
                    days: [:mon, :tue, :wed, :thu, :fri]
                  }
                ]
              }
            }
          }
        },
        security: %{
          encryption_at_rest: %{
            enabled: true,
            key_management: %{
              provider: :aws,
              key_rotation_period: 90,
              auto_rotation: true
            }
          },
          network: %{
            allowed_ips: ["10.0.0.0/8"],
            vpn: %{
              enabled: true,
              provider: "openvpn",
              settings: %{
                protocols: ["udp", "tcp"],
                ports: [1194, 443]
              }
            }
          },
          audit: %{
            enabled: true,
            retention: 90,
            storage: %{
              type: :remote,
              settings: %{
                path: "/var/log/audit",
                format: :json
              }
            }
          }
        }
      },
      resources: [
        %{
          id: "res_#{:crypto.strong_rand_bytes(16) |> Base.encode16()}",
          type: :compute,
          status: :active,
          metadata: %{
            created_at: NaiveDateTime.utc_now(),
            updated_at: NaiveDateTime.utc_now(),
            labels: ["prod", "web"]
          },
          specs: %{
            compute: %{
              cpu: 4,
              memory: 8192,
              gpu: %{
                enabled: false,
                count: 0,
                type: "none"
              }
            },
            storage: %{
              size: 100,
              type: :ssd,
              iops: 3000
            },
            network: %{
              bandwidth: 1000,
              public_ip: true,
              dns: %{
                enabled: true,
                records: [
                  %{
                    type: :a,
                    name: "www",
                    value: "10.0.0.1",
                    ttl: 3600
                  }
                ]
              }
            }
          }
        }
      ]
    }
  end

  def generate_invalid_data do
    valid = generate_valid_data()
    # Deliberately introduce type errors and missing required fields
    put_in(valid.configuration.features.authentication.providers, [
      %{
        # Invalid enum value
        type: :invalid_type,
        settings: %{
          # Should be string
          client_id: 123,
          # Should be list
          scopes: "not_a_list"
        }
      }
    ])
  end
end

# Run the benchmark
valid_data = Complex.generate_valid_data()
invalid_data = Complex.generate_invalid_data()
schema = Complex.get_schema(:organization)

Benchee.run(
  %{
    "complex schema - valid data" => fn ->
      Complex.organization(valid_data)
    end,
    "complex schema - invalid data" => fn ->
      Complex.organization(invalid_data)
    end,
    "complex ecto schema - valid data" => fn ->
      Peri.to_changeset!(schema, valid_data)
    end,
    "complex ecto schema - invalid data" => fn ->
      Peri.to_changeset!(schema, invalid_data)
    end
  },
  time: 10,
  memory_time: 2,
  warmup: 2,
  formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
)
