defmodule Simple do
  import Peri

  # Simple schema with basic types
  defschema(:simple_user, %{
    name: {:required, :string},
    age: {:required, :integer},
    email: :string
  })

  # Complex schema with nested structures
  defschema(:complex_user, %{
    personal_info:
      {:required,
       %{
         name: {:required, :string},
         age: {:required, :integer},
         email: :string
       }},
    addresses:
      {:list,
       %{
         street: {:required, :string},
         city: {:required, :string},
         country: {:required, :string}
       }},
    settings: %{
      notifications: {:required, :boolean},
      theme: {:enum, [:light, :dark]}
    }
  })
end

# Generate test data
simple_valid_data = %{
  name: "John Doe",
  age: 30,
  email: "john@example.com"
}

simple_invalid_data = %{
  # wrong type
  name: 123,
  # wrong type
  age: "30",
  email: nil
}

complex_valid_data = %{
  personal_info: %{
    name: "John Doe",
    age: 30,
    email: "john@example.com"
  },
  addresses: [
    %{street: "123 Main St", city: "Sample City", country: "Sample Country"},
    %{street: "456 Side St", city: "Other City", country: "Other Country"}
  ],
  settings: %{
    notifications: true,
    theme: :light
  }
}

complex_invalid_data = %{
  personal_info: %{
    # wrong type
    name: 123,
    # wrong type
    age: "30",
    email: nil
  },
  addresses: [
    # all wrong types
    %{street: nil, city: 123, country: true}
  ],
  settings: %{
    # wrong type
    notifications: "true",
    # invalid enum value
    theme: :invalid_theme
  }
}

Benchee.run(
  %{
    "simple schema - valid data" => fn ->
      Simple.simple_user(simple_valid_data)
    end,
    "simple schema - invalid data" => fn ->
      Simple.simple_user(simple_invalid_data)
    end,
    "complex schema - valid data" => fn ->
      Simple.complex_user(complex_valid_data)
    end,
    "complex schema - invalid data" => fn ->
      Simple.complex_user(complex_invalid_data)
    end,
    "simple schema - changeset" => fn ->
      Peri.to_changeset!(Simple.get_schema(:simple_user), simple_valid_data)
    end,
    "complex schema - changeset" => fn ->
      Peri.to_changeset!(Simple.get_schema(:complex_user), complex_valid_data)
    end
  },
  time: 10,
  memory_time: 2,
  formatters: [{Benchee.Formatters.Console, extended_statistics: true}]
)
